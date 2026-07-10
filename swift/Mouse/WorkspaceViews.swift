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

/// Lists the signed-in user's repositories; tapping one downloads it into the ring's workspace.
private struct RepoPickerView: View {
    let deck: CarouselDeck

    @State private var repos: [RepoSummary]?
    @State private var loadError: String?

    var body: some View {
        if case .signedIn = GitHubAuth.shared.phase {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    Text("open a repo")
                        .font(.custom(AppFont.asciiName, size: 12))
                        .opacity(0.55)
                        .padding(.bottom, 10)
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
                .padding(16)
            }
            .task {
                guard repos == nil, let token = GitHubAuth.shared.accessToken else { return }
                do { repos = try await RepoSummary.fetchMine(token: token) }
                catch { loadError = error.localizedDescription }
            }
        } else {
            Text("sign in with the GitHub container\nto open a repo")
                .font(.custom(AppFont.asciiName, size: 14))
                .multilineTextAlignment(.center)
                .opacity(0.6)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
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
            }
            .padding(16)
        }
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

/// A ring's editor buffer: the open file's contents, loaded the moment the file is CHOSEN
/// (tree tap, terminal `open`, restore) rather than when the viewer appears — so edge-swiping
/// a ring on screen shows the file instantly, with the load already done off screen. Also owns
/// dirty state and the debounced autosave, which now survive the view unmounting.
/// Main-thread only (all access is from SwiftUI / the deck); `@unchecked Sendable` exists solely
/// so the debounced-save Task may capture it — the task body hops back to the main actor.
@Observable
final class RingFileBuffer: @unchecked Sendable {
    var text = ""
    private(set) var note: String?
    private(set) var loadedURL: URL?
    private(set) var loadedPath: String?
    private var loadedWorkspace: Workspace?
    private var loadedTreeVersion = -1
    private var dirty = false
    private var suppressNextChange = false
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
        dirty = false
        loadedURL = url
    }

    /// Defensive sync for the viewer: (re)load if the selection changed without `load` (or the
    /// tree was replaced by a pull since this buffer loaded). No-op when already current.
    func ensure(path: String, workspace: Workspace) {
        if loadedPath != path || loadedWorkspace !== workspace
            || workspace.treeVersion != loadedTreeVersion {
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
        if let loadedWorkspace, let loadedPath { loadedWorkspace.markModified(loadedPath) }
    }
}

/// The Viewer container (kind 3): the ring's open file, edited in place. The content comes from
/// the ring's `RingFileBuffer`, already loaded at selection time — this view is a pure window,
/// so it renders complete on its first frame (no load flicker when a ring edge-swipes in).
struct ViewerContainerView: View {
    let deck: CarouselDeck?

    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if let deck, let workspace = deck.workspace, let path = deck.openFilePath {
                @Bindable var buffer = deck.fileBuffer
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
            if phase != .active { deck?.fileBuffer.flush() }
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

    var body: some View {
        if let workspace = deck.workspace, case .ready = workspace.phase,
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
            chip(state: workspace.pushState, pointingUp: true)
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
            chip(state: workspace.pullState, pointingUp: false)
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
                Text("Replaces the working tree — your \(workspace.modifiedPaths.count) unpushed edit\(workspace.modifiedPaths.count == 1 ? "" : "s") will be lost.")
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

    private func chip(state: Workspace.PushState, pointingUp: Bool) -> some View {
        Group {
            switch state {
            case .pushing:
                ProgressView().tint(.white).scaleEffect(0.5)
            case .failed:
                ChevronGlyph(pointingUp: pointingUp)
                    .stroke(style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                    .foregroundStyle(.red)
                    .frame(width: 7.5, height: 4.5)
            case .idle:
                ChevronGlyph(pointingUp: pointingUp)
                    .stroke(style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                    .foregroundStyle(.white)
                    .frame(width: 7.5, height: 4.5)
            }
        }
        .frame(width: chipDiameter, height: chipDiameter)
        .background(.white.opacity(0.16), in: Circle())
    }
}

/// A hand-drawn /\ (or \/) — two strokes meeting at a point, matching the app's ascii language.
struct ChevronGlyph: Shape {
    let pointingUp: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        if pointingUp {
            path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        } else {
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        }
        return path
    }
}
