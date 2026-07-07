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
                    FileTreeView(workspace: workspace)
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
        let workspace = Workspace(downloading: repo.fullName)
        deck.workspace = workspace
        Task {
            do {
                try await Workspace.fetchAndExtract(repo.fullName, token: token)
                workspace.finishReady()
            } catch {
                workspace.finishFailed(error.localizedDescription)
            }
        }
    }
}

/// The working tree: vertical scroll, tap a folder to expand, tap a file to open it in the
/// ring's viewer container. Directories load lazily as they're expanded.
private struct FileTreeView: View {
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
                workspace.openFilePath = node.path
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
                    .opacity(workspace.openFilePath == node.path ? 1 : 0.85)
            }
            .padding(.leading, CGFloat(node.depth) * 14)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                workspace.openFilePath == node.path ? Color.white.opacity(0.12) : .clear,
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

/// The Viewer container (kind 3): the workspace's open file, edited in place. Tapping the text
/// puts the caret there and raises the keyboard — no overlay, no mode; you're editing right in
/// the lane. Changes autosave (debounced) and flush on file switches and backgrounding; drag
/// the text downward to dismiss the keyboard. Vertical scroll and taps only, per the gesture
/// law; lines wrap; the spacebar-trackpad steers the caret.
struct ViewerContainerView: View {
    let workspace: Workspace?

    @Environment(\.scenePhase) private var scenePhase

    @State private var text = ""
    @State private var note: String?
    @State private var loadedURL: URL?
    @State private var dirty = false
    @State private var saveTask: Task<Void, Never>?

    var body: some View {
        Group {
            if let workspace, let path = workspace.openFilePath {
                VStack(alignment: .leading, spacing: 8) {
                    Text(path)
                        .font(.custom(AppFont.asciiName, size: 11))
                        .opacity(0.55)
                        .lineLimit(1)
                    if let note {
                        Text(note)
                            .font(.custom(AppFont.asciiName, size: 13))
                            .opacity(0.6)
                        Spacer(minLength: 0)
                    } else {
                        TextEditor(text: $text)
                            .font(.custom(AppFont.asciiName, size: 12))
                            .foregroundStyle(.white)
                            .scrollContentBackground(.hidden)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .keyboardType(.asciiCapable)
                            .scrollDismissesKeyboard(.interactively)
                            .onChange(of: text) { _, _ in markDirtyAndScheduleSave() }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .task(id: workspace.root.path + "::" + path) { open(path, in: workspace) }
            } else {
                Text("open a file in the Files container")
                    .font(.custom(AppFont.asciiName, size: 14))
                    .opacity(0.6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .foregroundStyle(.white)
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { flush() }
        }
    }

    private func open(_ path: String, in workspace: Workspace) {
        flush()  // pending edits to the previous file land before switching
        saveTask?.cancel()
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
        text = content
        dirty = false
        loadedURL = url
    }

    private func markDirtyAndScheduleSave() {
        guard loadedURL != nil else { return }
        dirty = true
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .seconds(0.8))
            guard !Task.isCancelled else { return }
            flush()
        }
    }

    private func flush() {
        guard dirty, let loadedURL else { return }
        try? text.write(to: loadedURL, atomically: true, encoding: .utf8)
        dirty = false
    }
}
