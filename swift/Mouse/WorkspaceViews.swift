import SwiftUI

/// The Files container (kind 2): picks a repo when the ring has no workspace yet, then shows the
/// working tree. Under the gesture law, everything here is taps and vertical scrolling — lane
/// swipes and ring gestures pass through untouched.
struct FilesContainerView: View {
    let deck: CarouselDeck

    var body: some View {
        Group {
            if let workspace = deck.workspace {
                switch workspace.phase {
                case .downloading:
                    VStack(spacing: 12) {
                        ProgressView().tint(.white)
                        Text("downloading \(workspace.repoFullName)…")
                            .font(.custom(AppFont.asciiName, size: 13))
                            .opacity(0.7)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .failed(let message):
                    VStack(spacing: 12) {
                        Text(message)
                            .font(.custom(AppFont.asciiName, size: 13))
                            .multilineTextAlignment(.center)
                            .opacity(0.85)
                            .padding(.horizontal, 24)
                        Button { deck.workspace = nil } label: {
                            Text("pick another repo")
                                .font(.custom(AppFont.asciiName, size: 14))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(.white.opacity(0.16), in: Capsule())
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .ready:
                    FileTreeView(deck: deck, workspace: workspace)
                }
            } else {
                RepoPickerView(deck: deck)
            }
        }
        .foregroundStyle(.white)
    }
}

/// Picks the ring's project: a fresh LOCAL project (no GitHub needed — code offline, or when
/// the API is having a bad day), or one of the signed-in user's repositories.
private struct RepoPickerView: View {
    let deck: CarouselDeck

    @State private var repos: [RepoSummary]?
    @State private var loadError: String?
    @State private var askingName = false
    @State private var projectName = ""
    @State private var localProjects: [String] = []

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                Text("start a project")
                    .font(.custom(AppFont.asciiName, size: 12))
                    .opacity(0.55)
                    .padding(.bottom, 10)
                Button { askingName = true } label: {
                    Text("+ new local project")
                        .font(.custom(AppFont.asciiName, size: 14))
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(localProjects, id: \.self) { project in
                    Button {
                        deck.workspace = Workspace.shared(for: project)
                    } label: {
                        Text(String(project.dropFirst("local/".count)))
                            .font(.custom(AppFont.asciiName, size: 14))
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                Text(signedIn ? "or open a repo" : "sign in with the GitHub container to open a repo")
                    .font(.custom(AppFont.asciiName, size: 12))
                    .opacity(0.55)
                    .padding(.top, 14)
                    .padding(.bottom, 10)
                if signedIn {
                    if let loadError {
                        Text(loadError)
                            .font(.custom(AppFont.asciiName, size: 13))
                            .opacity(0.85)
                    } else if let repos {
                        ForEach(repos) { repo in
                            Button { open(repo) } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(repo.fullName)
                                        .font(.custom(AppFont.asciiName, size: 14))
                                    if let description = repo.description, !description.isEmpty {
                                        Text(description)
                                            .font(.custom(AppFont.asciiName, size: 11))
                                            .opacity(0.5)
                                            .lineLimit(1)
                                    }
                                }
                                .padding(.vertical, 6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    } else {
                        Text("loading…")
                            .font(.custom(AppFont.asciiName, size: 13))
                            .opacity(0.55)
                    }
                }
            }
            .padding(16)
        }
        .task {
            localProjects = Workspace.localProjectNames()
            guard repos == nil, let token = GitHubAuth.shared.accessToken else { return }
            do { repos = try await RepoSummary.fetchMine(token: token) }
            catch { loadError = error.localizedDescription }
        }
        .alert("New local project", isPresented: $askingName) {
            TextField("project name", text: $projectName)
                .textInputAutocapitalization(.never)
            Button("Create") {
                deck.workspace = Workspace.local(named: projectName)
                projectName = ""
            }
            Button("Cancel", role: .cancel) { projectName = "" }
        }
    }

    private var signedIn: Bool {
        if case .signedIn = GitHubAuth.shared.phase { return true }
        return false
    }

    private func open(_ repo: RepoSummary) {
        guard let token = GitHubAuth.shared.accessToken else { return }
        // One workspace per repo: if another ring already has this repo (or its tree is still
        // on disk from before), attaching is instant and both rings view the same workspace.
        let workspace = Workspace.shared(for: repo.fullName)
        deck.workspace = workspace
        workspace.startDownload(token: token)
    }
}

/// The working tree: vertical scroll, tap a folder to expand, tap a file to open it in the
/// ring's viewer container. Directories load lazily as they're expanded.
private struct FileTreeView: View {
    let deck: CarouselDeck
    let workspace: Workspace
    @State private var expanded: Set<String> = []
    @State private var askingNewFile = false
    @State private var newFileName = ""

    private struct Node: Identifiable {
        let path: String
        let name: String
        let isDirectory: Bool
        let depth: Int
        var id: String { path }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                Text(workspace.repoFullName)
                    .font(.custom(AppFont.asciiName, size: 12))
                    .opacity(0.55)
                    .padding(.bottom, 10)
                ForEach(visibleNodes()) { node in
                    row(node)
                }
                Button { askingNewFile = true } label: {
                    Text("+ add file")
                        .font(.custom(AppFont.asciiName, size: 13))
                        .opacity(0.55)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(16)
        }
        .alert("New file", isPresented: $askingNewFile) {
            TextField("name", text: $newFileName)
                .textInputAutocapitalization(.never)
            Button("Create") { createFile() }
            Button("Cancel", role: .cancel) { newFileName = "" }
        }
    }

    /// Create an empty file (subfolders in the name are created too), mark it for push, and
    /// open it in the ring's viewer with its ancestors expanded.
    private func createFile() {
        let name = newFileName.trimmingCharacters(in: .whitespaces)
        newFileName = ""
        guard !name.isEmpty else { return }
        let pieces = name.split(separator: "/").map(String.init).filter { $0 != ".." && $0 != "." }
        guard !pieces.isEmpty else { return }
        let rel = pieces.joined(separator: "/")
        let url = workspace.root.appendingPathComponent(rel)
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: Data())
            workspace.markModified(rel)
        }
        var ancestor = ""
        for piece in pieces.dropLast() {
            ancestor = ancestor.isEmpty ? piece : ancestor + "/" + piece
            expanded.insert(ancestor)
        }
        deck.openFile(rel)
    }

    private func row(_ node: Node) -> some View {
        Button {
            if node.isDirectory {
                if expanded.contains(node.path) { expanded.remove(node.path) }
                else { expanded.insert(node.path) }
            } else {
                deck.openFile(node.path)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: node.isDirectory
                    ? (expanded.contains(node.path) ? "chevron.down" : "chevron.right")
                    : "doc")
                    .font(.system(size: 10, weight: .semibold))
                    .opacity(node.isDirectory ? 0.8 : 0.4)
                    .frame(width: 12)
                Text(node.name)
                    .font(.custom(AppFont.asciiName, size: 13))
                    .opacity(deck.openFilePath == node.path ? 1 : 0.85)
            }
            .padding(.leading, CGFloat(node.depth) * 14)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                deck.openFilePath == node.path ? Color.white.opacity(0.12) : .clear,
                in: RoundedRectangle(cornerRadius: 6)
            )
        }
    }

    private func visibleNodes() -> [Node] {
        var nodes: [Node] = []
        appendChildren(of: "", depth: 0, into: &nodes)
        return nodes
    }

    private func appendChildren(of relativePath: String, depth: Int, into nodes: inout [Node]) {
        let dir = relativePath.isEmpty
            ? workspace.root
            : workspace.root.appendingPathComponent(relativePath)
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []
        let sorted = entries
            .map { (url: $0, isDirectory: (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false) }
            .filter { $0.url.lastPathComponent != ".git" }
            .sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.url.lastPathComponent.localizedCaseInsensitiveCompare($1.url.lastPathComponent) == .orderedAscending
            }
        for entry in sorted {
            let name = entry.url.lastPathComponent
            let path = relativePath.isEmpty ? name : relativePath + "/" + name
            nodes.append(Node(path: path, name: name, isDirectory: entry.isDirectory, depth: depth))
            if entry.isDirectory, expanded.contains(path) {
                appendChildren(of: path, depth: depth + 1, into: &nodes)
            }
        }
    }
}

/// A live document: one buffer per file, app-wide, shared by every view of it. Rings opening
/// the same file bind to the SAME buffer, so a keystroke in one ring is instantly the other's
/// content — Google-Docs behavior with zero merge machinery, because on one device there is
/// only one replica (OT/CRDTs earn their keep only when devices sync over a network). Loaded
/// the moment a file is CHOSEN (tree tap, terminal `open`, restore), never when a view appears,
/// so edge-swiped rings render complete on their first frame. Owns dirty state and autosave.
/// Main-thread only; `@unchecked Sendable` exists solely so the debounced-save Task may capture
/// it — the task body hops back to the main actor.
@Observable
final class FileBuffer: @unchecked Sendable {
    /// One buffer per (workspace, file), app-wide. Never evicts, like the other registries.
    nonisolated(unsafe) private static var byFile: [String: FileBuffer] = [:]

    /// The shared buffer for a file, loading it on first request.
    static func shared(for workspace: Workspace, path: String) -> FileBuffer {
        let key = workspace.root.path + "::" + path
        if let live = byFile[key] { return live }
        let fresh = FileBuffer()
        fresh.load(path: path, workspace: workspace)
        byFile[key] = fresh
        return fresh
    }

    /// Pending edits in every open buffer land on disk (backgrounding, any ring, mounted or not).
    static func flushAll() {
        byFile.values.forEach { $0.flush() }
    }

    /// After a push, what's on disk IS the remote: re-anchor open buffers' baselines so the
    /// next edit is measured against the pushed content, not the pre-push load.
    static func rebaseline(for workspace: Workspace) {
        for buffer in byFile.values where buffer.loadedWorkspace === workspace {
            buffer.baseline = buffer.text
        }
    }
    var text = ""
    private(set) var note: String?
    private(set) var loadedURL: URL?
    private(set) var loadedPath: String?
    private var loadedWorkspace: Workspace?
    private var loadedTreeVersion = -1
    private var dirty = false
    private var suppressNextChange = false
    /// The content as loaded from the tree — the "no real change" reference. A flush whose
    /// text equals this UNMARKS the file: type a space, delete it, and there is nothing to
    /// push. (Baseline is per-load: after an app restart atop unpushed edits, those edits
    /// are the baseline and stay marked via the persisted dirty set.)
    private var baseline = ""
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    var hasDocument: Bool { loadedURL != nil }

    /// Load `path` (flushing pending edits to the previous file first).
    func load(path: String?, workspace: Workspace?) {
        flush()
        saveTask?.cancel()
        guard let path, let workspace else {
            loadedURL = nil
            loadedPath = nil
            loadedWorkspace = nil
            note = nil
            suppressNextChange = true
            text = ""
            baseline = ""
            return
        }
        loadedPath = path
        loadedWorkspace = workspace
        loadedTreeVersion = workspace.treeVersion
        let url = workspace.root.appendingPathComponent(path)
        guard let data = try? Data(contentsOf: url) else {
            loadedURL = nil; note = "couldn't read the file"; return
        }
        guard data.count < 1_500_000 else {
            loadedURL = nil; note = "file is too large to view (\(data.count / 1024) KB)"; return
        }
        guard let content = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1) else {
            loadedURL = nil; note = "binary file"; return
        }
        note = nil
        suppressNextChange = true
        text = content
        baseline = content
        dirty = false
        loadedURL = url
    }

    /// Defensive sync for the viewer: reload when the tree was replaced by a pull (discarding
    /// local edits — the pull already warned about that; flushing first would overwrite the
    /// pulled file with stale text) or, defensively, when the selection changed without `load`.
    func ensure(path: String, workspace: Workspace) {
        if workspace.treeVersion != loadedTreeVersion, loadedPath == path, loadedWorkspace === workspace {
            dirty = false
            saveTask?.cancel()
            load(path: path, workspace: workspace)
        } else if loadedPath != path || loadedWorkspace !== workspace {
            load(path: path, workspace: workspace)
        }
    }

    /// Editor keystroke: mark dirty and schedule the debounced write (programmatic loads are
    /// suppressed — viewing a file must never mark it modified).
    func textDidChange() {
        if suppressNextChange {
            suppressNextChange = false
            return
        }
        guard loadedURL != nil else { return }
        dirty = true
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.8))
            guard !Task.isCancelled else { return }
            self.flush()
        }
    }

    func flush() {
        guard dirty, let loadedURL else { return }
        try? text.write(to: loadedURL, atomically: true, encoding: .utf8)
        dirty = false
        guard let loadedWorkspace, let loadedPath else { return }
        // Only a REAL difference from the loaded content counts as a change to push; an edit
        // that round-tripped back to the baseline clears the flag it may have set earlier.
        if text == baseline {
            loadedWorkspace.unmarkModified(loadedPath)
        } else {
            loadedWorkspace.markModified(loadedPath)
        }
    }
}

/// The Viewer container (kind 3): the ring's open file, edited in place. The content is the
/// app-wide shared `FileBuffer` for that file, already loaded at selection time — this view is
/// a pure window, so it renders complete on its first frame (no load flicker when a ring
/// edge-swipes in), and every ring viewing the same file shows the same live document.
struct ViewerContainerView: View {
    let deck: CarouselDeck?

    @Environment(\.scenePhase) private var scenePhase
    /// Mirrored onto the deck so the shell knows when drags on this container belong to the
    /// text (selection handles, caret) rather than the lane. Reflects first-responder status.
    @FocusState private var editorFocused: Bool

    var body: some View {
        Group {
            if let deck, let workspace = deck.workspace, let path = deck.openFilePath {
                @Bindable var buffer = FileBuffer.shared(for: workspace, path: path)
                VStack(alignment: .leading, spacing: 8) {
                    Text(path)
                        .font(.custom(AppFont.asciiName, size: 11))
                        .opacity(0.55)
                        .lineLimit(1)
                    if let note = buffer.note {
                        Text(note)
                            .font(.custom(AppFont.asciiName, size: 13))
                            .opacity(0.6)
                        Spacer(minLength: 0)
                    } else if buffer.hasDocument {
                        TextEditor(text: $buffer.text)
                            .font(.custom(AppFont.asciiName, size: 12))
                            .foregroundStyle(.white)
                            .scrollContentBackground(.hidden)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .keyboardType(.asciiCapable)
                            .scrollDismissesKeyboard(.interactively)
                            .focused($editorFocused)
                            .onChange(of: editorFocused) { _, focused in deck.editorFocused = focused }
                            // Belt and braces: keyboard gone = editing over, whatever hid it
                            // (tap-outside resigns the UITextView directly; FocusState can lag).
                            .onReceive(NotificationCenter.default.publisher(
                                for: UIResponder.keyboardWillHideNotification)) { _ in
                                deck.editorFocused = false
                            }
                            .onChange(of: buffer.text) { _, _ in buffer.textDidChange() }
                    } else {
                        Spacer(minLength: 0)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .task(id: "\(workspace.root.path)::\(path)::t\(workspace.treeVersion)") {
                    buffer.ensure(path: path, workspace: workspace)
                }
            } else {
                Text("open a file in the Files container")
                    .font(.custom(AppFont.asciiName, size: 14))
                    .opacity(0.6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .foregroundStyle(.white)
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { FileBuffer.flushAll() }
        }
    }
}

/// The container's top-right action stack: a horizontal row of small round buttons tucked into
/// the corner, each appearing only when its prerequisites are met. Actions so far: commit & push
/// local edits (∧, shown once the workspace has modified files) and pull the latest tree from
/// GitHub (∨, shown whenever a ready workspace and a GitHub session exist).
struct ContainerActionsRow: View {
    let deck: CarouselDeck
    let cornerRadius: CGFloat

    /// Inset from the container's corner.
    static let inset: CGFloat = 8

    @State private var askingPush = false
    @State private var askingPull = false
    @State private var commitMessage = ""

    private var chipDiameter: CGFloat { 22 }
    /// Slot width — per the sketch: wide slots, not circles.
    private var chipWidth: CGFloat { 44 }

    var body: some View {
        if let workspace = deck.workspace, !workspace.isLocal, case .ready = workspace.phase,
           case .signedIn = GitHubAuth.shared.phase {
            HStack(spacing: 8) {
                if workspace.hasChanges {
                    pushButton(workspace)
                }
                if workspace.upstreamAvailable {
                    pullButton(workspace)
                }
            }
            .task(id: "\(workspace.repoFullName)#\(workspace.treeVersion)") {
                // Discover upstream commits (throttled inside) and keep the commit graph
                // warm in the background — the Graph container renders instantly on swipe-in.
                if let token = GitHubAuth.shared.accessToken {
                    await workspace.refreshUpstream(token: token)
                    await workspace.refreshHistory(token: token)
                }
            }
        }
    }

    // MARK: - Push (∧)

    private func pushButton(_ workspace: Workspace) -> some View {
        Button {
            commitMessage = ""
            askingPush = true
        } label: {
            chip(state: workspace.pushState, color: GitGraph.railColors[3])   // green
        }
        .disabled(isBusy(workspace.pushState))
        .alert(pushTitle(workspace), isPresented: $askingPush) {
            TextField("Commit message", text: $commitMessage)
                .textInputAutocapitalization(.sentences)
            Button("Commit & Push") { push(workspace) }
            Button("Cancel", role: .cancel) {}
        } message: {
            if case .failed(let reason) = workspace.pushState {
                Text("Last attempt failed: \(reason)")
            }
        }
    }

    private func pushTitle(_ workspace: Workspace) -> String {
        let count = workspace.modifiedPaths.count
        return "Commit \(count) file\(count == 1 ? "" : "s") to \(workspace.repoFullName)"
    }

    private func push(_ workspace: Workspace) {
        guard let token = GitHubAuth.shared.accessToken else { return }
        let count = workspace.modifiedPaths.count
        let message = commitMessage.isEmpty
            ? "Edit \(count) file\(count == 1 ? "" : "s") from Mouse"
            : commitMessage
        let paths = Array(workspace.modifiedPaths)
        workspace.pushState = .pushing
        Task {
            do {
                let commitSha = try await GitHubPush.push(
                    repo: workspace.repoFullName,
                    root: workspace.root,
                    paths: paths,
                    message: message,
                    token: token
                )
                workspace.clearModified()
                workspace.markSynced(to: commitSha)
                FileBuffer.rebaseline(for: workspace)
                workspace.pushState = .idle
                await workspace.refreshHistory(token: token)  // our commit appears in the graph
            } catch {
                workspace.pushState = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: - Pull (∨)

    private func pullButton(_ workspace: Workspace) -> some View {
        Button {
            askingPull = true
        } label: {
            chip(state: workspace.pullState, color: GitGraph.railColors[6])   // blue
        }
        .disabled(isBusy(workspace.pullState))
        .alert(pullTitle(workspace), isPresented: $askingPull) {
            Button(workspace.hasChanges ? "Discard & Pull" : "Pull", role: workspace.hasChanges ? .destructive : nil) {
                pull(workspace)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if case .failed(let reason) = workspace.pullState {
                Text("Last attempt failed: \(reason)")
            } else if workspace.hasChanges {
                Text("Replaces the working tree. \(workspace.modifiedPaths.count) unpushed edit\(workspace.modifiedPaths.count == 1 ? "" : "s") will be lost.")
            }
        }
    }

    private func pullTitle(_ workspace: Workspace) -> String {
        "Pull the latest \(workspace.repoFullName)"
    }

    private func pull(_ workspace: Workspace) {
        guard let token = GitHubAuth.shared.accessToken else { return }
        workspace.pullState = .pushing
        Task {
            do {
                try await Workspace.fetchAndExtract(workspace.repoFullName, token: token)
                let sha = try? await Workspace.remoteHeadSha(workspace.repoFullName, token: token)
                workspace.markSynced(to: sha)
                workspace.clearModified()
                workspace.treeVersion += 1  // file views reload against the new tree
                workspace.pullState = .idle
                await workspace.refreshHistory(token: token)
            } catch {
                workspace.pullState = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: - Chip

    private func isBusy(_ state: Workspace.PushState) -> Bool {
        if case .pushing = state { return true }
        return false
    }

    /// Slot-shaped (capsule) action buttons: no glyphs — the color IS the identity.
    /// Push is green (outgoing work), pull is blue (incoming), failure red. The hues come
    /// from the graph-rail palette, so no new colors enter the system.
    private func chip(state: Workspace.PushState, color: Color) -> some View {
        Group {
            if case .pushing = state {
                ProgressView().tint(.black).scaleEffect(0.5)
            }
        }
        .frame(width: chipWidth, height: chipDiameter)
        .background(slotColor(for: state, idle: color), in: Capsule())
        .contentShape(Capsule())
    }

    private func slotColor(for state: Workspace.PushState, idle: Color) -> Color {
        if case .failed = state { return .red }
        return idle
    }
}

