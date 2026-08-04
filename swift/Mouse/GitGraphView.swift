import SwiftUI

/// The Graph container (kind 4): the ring's workspace as a commit graph — colored branch rails,
/// dots for commits, rings for merges, branch tips labeled. History comes from the GitHub API
/// (the workspace has no .git until libgit2 arrives; when it does, only the data source changes).
/// Vertical scroll only, per the gesture law.

struct CommitNode: Sendable {
    let sha: String
    let message: String
    let author: String
    let parents: [String]
}

/// One rendered row of the graph: which column the commit's dot sits in, the rail state around
/// it, and which rails curve in (children joining) or out (merge parents opening).
struct GraphRow: Identifiable {
    let commit: CommitNode
    let column: Int
    let lanesBefore: [String?]
    let lanesAfter: [String?]
    let joins: [Int]
    let opens: [Int]
    var id: String { commit.sha }
}

enum GitGraph {
    /// Classic commit-graph lane assignment, newest first: each rail carries the sha it expects
    /// next. A commit lands on the first rail expecting it (other expecting rails curve in and
    /// close — branch points), or opens a new rail (a branch tip). Its first parent inherits the
    /// rail; extra parents (merges) connect to existing rails or open new ones.
    static func layout(_ commits: [CommitNode]) -> [GraphRow] {
        var lanes: [String?] = []
        var rows: [GraphRow] = []
        for commit in commits {
            let lanesBefore = lanes
            var joins: [Int] = []
            let column: Int
            let expecting = lanes.indices.filter { lanes[$0] == commit.sha }
            if let first = expecting.first {
                column = first
                for other in expecting.dropFirst() {
                    lanes[other] = nil
                    joins.append(other)
                }
            } else {
                if let free = lanes.firstIndex(where: { $0 == nil }) {
                    column = free
                } else {
                    column = lanes.count
                    lanes.append(nil)
                }
            }
            lanes[column] = commit.parents.first

            var opens: [Int] = []
            for parent in commit.parents.dropFirst() {
                if let existing = lanes.firstIndex(of: parent) {
                    opens.append(existing)
                } else if let free = lanes.firstIndex(where: { $0 == nil }), free != column {
                    lanes[free] = parent
                    opens.append(free)
                } else {
                    lanes.append(parent)
                    opens.append(lanes.count - 1)
                }
            }
            rows.append(GraphRow(
                commit: commit, column: column,
                lanesBefore: lanesBefore, lanesAfter: lanes,
                joins: joins, opens: opens
            ))
        }
        return rows
    }

    /// Rail palette — cycles by column.
    static let railColors: [Color] = [.orange, .pink, .cyan, .green, .purple, .yellow, .blue, .red]

    static func color(_ lane: Int) -> Color { railColors[lane % railColors.count] }

    // MARK: - GitHub history fetch

    struct History: Sendable {
        let commits: [CommitNode]
        /// Branch tip labels, keyed by sha.
        let branchTips: [String: String]
    }

    static func fetchHistory(repo: String, token: String) async throws -> History {
        async let commitsData = get("https://api.github.com/repos/\(repo)/commits?per_page=80", token: token)
        async let branchesData = get("https://api.github.com/repos/\(repo)/branches?per_page=50", token: token)

        struct APICommit: Decodable {
            struct Inner: Decodable {
                struct Person: Decodable { let name: String? }
                let message: String
                let author: Person?
            }
            struct Parent: Decodable { let sha: String }
            let sha: String
            let commit: Inner
            let parents: [Parent]
        }
        struct APIBranch: Decodable {
            struct Tip: Decodable { let sha: String }
            let name: String
            let commit: Tip
        }

        let decoder = JSONDecoder()
        let commits = try decoder.decode([APICommit].self, from: await commitsData).map {
            CommitNode(
                sha: $0.sha,
                message: $0.commit.message.components(separatedBy: "\n")[0],
                author: $0.commit.author?.name ?? "",
                parents: $0.parents.map(\.sha)
            )
        }
        var tips: [String: String] = [:]
        if let branches = try? decoder.decode([APIBranch].self, from: await branchesData) {
            for branch in branches { tips[branch.commit.sha] = branch.name }
        }
        return History(commits: commits, branchTips: tips)
    }

    private static func get(_ urlString: String, token: String) async throws -> Data {
        var request = URLRequest(url: URL(string: urlString)!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw TarGz.ExtractError("GitHub returned \(http.statusCode) for history")
        }
        return data
    }
}

struct GitGraphContainerView: View {
    let workspace: Workspace?
    /// The ring, for the git toolbar's terminal reporting. Optional so previews/other callers work.
    var deck: CarouselDeck? = nil

    private let laneWidth: CGFloat = 14
    private let rowHeight: CGFloat = 34

    var body: some View {
        Group {
            if let workspace {
                VStack(alignment: .leading, spacing: 0) {
                    Text("\(workspace.repoFullName) history")
                        .font(.custom(AppFont.asciiName, size: 11))
                        .opacity(0.55)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let deck {
                        // The git module's toolbar rides its own row beneath the title so all four
                        // controls have room on a narrow phone.
                        GitModuleToolbar(deck: deck, workspace: workspace)
                            .padding(.top, 8)
                    }
                    Color.clear.frame(height: 8)
                    if let rows = workspace.graphRows, !rows.isEmpty {
                        graph(rows, tips: workspace.graphTips)
                    } else if workspace.hasLocalRepo || workspace.isLocal {
                        Text("no commits yet")
                            .font(.custom(AppFont.asciiName, size: 13))
                            .opacity(0.55)
                            .padding(.top, 8)
                    } else if let error = workspace.graphError {
                        Text(error)
                            .font(.custom(AppFont.asciiName, size: 13))
                            .opacity(0.85)
                            .padding(.top, 8)
                    } else if GitHubAuth.shared.accessToken == nil {
                        Text("sign in with the GitHub container first")
                            .font(.custom(AppFont.asciiName, size: 13))
                            .opacity(0.55)
                            .padding(.top, 8)
                    } else {
                        Text("loading…")
                            .font(.custom(AppFont.asciiName, size: 13))
                            .opacity(0.55)
                            .padding(.top, 8)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .task(id: workspace.repoFullName + "::t\(workspace.treeVersion)") {
                    // Recompute the toolbar's enable/disable state, then warm the graph. Local
                    // repos need no token. Deduped inside refreshHistory.
                    workspace.refreshGitState()
                    await workspace.refreshHistory(token: GitHubAuth.shared.accessToken)
                }
            } else {
                Text("open a project in the Files container")
                    .font(.custom(AppFont.asciiName, size: 14))
                    .opacity(0.6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .foregroundStyle(.white)
    }

    private func graph(_ rows: [GraphRow], tips: [String: String]) -> some View {
        let laneCount = min(rows.map { max($0.lanesBefore.count, $0.lanesAfter.count) }.max() ?? 1, 8)
        let railsWidth = CGFloat(laneCount) * laneWidth + 4
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { row in
                    HStack(spacing: 10) {
                        rails(row)
                            .frame(width: railsWidth, height: rowHeight)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                if let tip = tips[row.commit.sha] {
                                    Text(tip)
                                        .font(.custom(AppFont.asciiName, size: 10))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 1)
                                        .background(GitGraph.color(row.column).opacity(0.35), in: Capsule())
                                }
                                Text(row.commit.message)
                                    .font(.custom(AppFont.asciiName, size: 12))
                                    .lineLimit(1)
                            }
                            Text("\(String(row.commit.sha.prefix(7)))  \(row.commit.author)")
                                .font(.custom(AppFont.asciiName, size: 10))
                                .opacity(0.4)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(height: rowHeight)
                }
            }
            .padding(.bottom, 12)
        }
    }

    /// One row's slice of the rails: pass-through verticals, curves for joins (children closing
    /// into this commit) and opens (merge parents fanning out), and the commit dot — a ring for
    /// merges, filled otherwise.
    private func rails(_ row: GraphRow) -> some View {
        Canvas { context, size in
            let midY = size.height / 2
            let x: (Int) -> CGFloat = { CGFloat($0) * self.laneWidth + self.laneWidth / 2 }
            let dotX = x(row.column)

            func stroke(_ path: Path, _ lane: Int) {
                context.stroke(path, with: .color(GitGraph.color(lane)), lineWidth: 2)
            }

            // Pass-through rails (active before and after, not this commit's column).
            for lane in 0..<max(row.lanesBefore.count, row.lanesAfter.count) where lane != row.column {
                let activeBefore = lane < row.lanesBefore.count && row.lanesBefore[lane] != nil
                let activeAfter = lane < row.lanesAfter.count && row.lanesAfter[lane] != nil
                if activeBefore && activeAfter && !row.joins.contains(lane) && !row.opens.contains(lane) {
                    stroke(Path { $0.move(to: CGPoint(x: x(lane), y: 0)); $0.addLine(to: CGPoint(x: x(lane), y: size.height)) }, lane)
                }
            }
            // The commit's own rail: from children above, to first parent below.
            if row.lanesBefore.indices.contains(row.column), row.lanesBefore[row.column] != nil {
                stroke(Path { $0.move(to: CGPoint(x: dotX, y: 0)); $0.addLine(to: CGPoint(x: dotX, y: midY)) }, row.column)
            }
            if row.lanesAfter.indices.contains(row.column), row.lanesAfter[row.column] != nil {
                stroke(Path { $0.move(to: CGPoint(x: dotX, y: midY)); $0.addLine(to: CGPoint(x: dotX, y: size.height)) }, row.column)
            }
            // Children rails curving in to end at this commit.
            for lane in row.joins {
                stroke(Path {
                    $0.move(to: CGPoint(x: x(lane), y: 0))
                    $0.addQuadCurve(to: CGPoint(x: dotX, y: midY), control: CGPoint(x: x(lane), y: midY))
                }, lane)
            }
            // Merge parents fanning out below (and continuing on their rail).
            for lane in row.opens {
                stroke(Path {
                    $0.move(to: CGPoint(x: dotX, y: midY))
                    $0.addQuadCurve(to: CGPoint(x: x(lane), y: size.height), control: CGPoint(x: x(lane), y: midY))
                }, lane)
            }
            // The dot: merges are rings, commits are filled.
            let radius: CGFloat = 4.5
            let dotRect = CGRect(x: dotX - radius, y: midY - radius, width: radius * 2, height: radius * 2)
            if row.commit.parents.count > 1 {
                context.stroke(Path(ellipseIn: dotRect), with: .color(GitGraph.color(row.column)), lineWidth: 2)
            } else {
                context.fill(Path(ellipseIn: dotRect), with: .color(GitGraph.color(row.column)))
            }
        }
    }

}

/// The git module's toolbar: five always-present controls in the Graph container's header —
/// `commit · sync · branch · merge · refresh`. Unlike the old corner slots (which appeared only when
/// usable), these pre-exist and gray out (dim, ~0.28) until their prerequisite is met, so their
/// place in the header is stable. A tap on a dimmed control isn't dead: it states WHY it's
/// unavailable in the ring's terminal (the app's one honest error surface). The native git
/// engine (`GitCore`/`GitRemote`) backs commit, branch, and merge; sync uses it for repos with a
/// local `.git` and the Data API for downloaded (tarball) repos.
struct GitModuleToolbar: View {
    let deck: CarouselDeck
    let workspace: Workspace

    @State private var askingCommit = false
    @State private var commitMessage = ""
    @State private var askingBranch = false
    @State private var askingNewBranch = false
    @State private var newBranchName = ""
    @State private var askingMerge = false
    @State private var askingSyncPush = false      // tarball push needs a commit message
    @State private var refreshing = false

    var body: some View {
        HStack(spacing: 12) {
            control("commit", enabled: canCommit) { commitTapped() }
            control("sync", enabled: canSync, busy: isBusy(workspace.pushState), failed: isFailed(workspace.pushState)) { syncTapped() }
            control("branch", enabled: canBranch) { branchTapped() }
            control("merge", enabled: canMerge) { mergeTapped() }
            control("refresh", enabled: true, busy: refreshing) { refreshTapped() }
        }
        // commit — message prompt
        .alert("Commit \(workspace.repoFullName)", isPresented: $askingCommit) {
            TextField("Message", text: $commitMessage).textInputAutocapitalization(.sentences)
            Button("Commit") { commit() }
            Button("Cancel", role: .cancel) {}
        }
        // sync (tarball push) — message prompt
        .alert(syncPushTitle, isPresented: $askingSyncPush) {
            TextField("Message", text: $commitMessage).textInputAutocapitalization(.sentences)
            Button("Commit & Push") { dataPush() }
            Button("Cancel", role: .cancel) {}
        }
        // branch — switch to an existing branch or start a new one
        .confirmationDialog("Branch", isPresented: $askingBranch, titleVisibility: .visible) {
            ForEach(workspace.localBranches, id: \.self) { name in
                if name != workspace.currentGitBranch {
                    Button("switch to \(name)") { switchBranch(name) }
                }
            }
            Button("new branch…") { newBranchName = ""; askingNewBranch = true }
            Button("Cancel", role: .cancel) {}
        }
        .alert("New branch", isPresented: $askingNewBranch) {
            TextField("name", text: $newBranchName).textInputAutocapitalization(.never)
            Button("Create") { createBranch() }
            Button("Cancel", role: .cancel) {}
        }
        // merge — pick a branch to merge into the current one
        .confirmationDialog("Merge into \(workspace.currentGitBranch)", isPresented: $askingMerge, titleVisibility: .visible) {
            ForEach(workspace.localBranches, id: \.self) { name in
                if name != workspace.currentGitBranch {
                    Button(name) { merge(name) }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: - Enablement

    private var signedIn: Bool {
        if case .signedIn = GitHubAuth.shared.phase { return true }
        return false
    }
    private var signedInLogin: String? {
        if case .signedIn(let login) = GitHubAuth.shared.phase { return login }
        return nil
    }

    private var canCommit: Bool {
        workspace.hasLocalRepo && (workspace.hasUncommittedChanges || workspace.hasChanges)
    }
    private var canSync: Bool {
        guard signedIn else { return false }
        return workspace.hasLocalRepo ? workspace.unpushedCommits : (workspace.hasChanges || workspace.upstreamAvailable)
    }
    private var canBranch: Bool { workspace.hasLocalRepo && workspace.hasCommits }
    private var canMerge: Bool { workspace.hasLocalRepo && workspace.localBranches.count >= 2 }

    // MARK: - Taps (dimmed controls explain themselves in the terminal)

    private func commitTapped() {
        if canCommit { commitMessage = ""; askingCommit = true }
        else if !workspace.hasLocalRepo { report("commit: no local git repo (this project was downloaded, not cloned)") }
        else { report("commit: nothing to commit, working tree clean") }
    }

    private func syncTapped() {
        guard signedIn else { return report("sync: sign in with the GitHub container first") }
        if workspace.hasLocalRepo {
            if workspace.unpushedCommits { gitPush() }
            else { report("sync: nothing to push (git pull in the terminal brings down remote commits)") }
        } else if workspace.hasChanges {
            commitMessage = ""; askingSyncPush = true
        } else if workspace.upstreamAvailable {
            dataPull()
        } else {
            report("sync: nothing to sync, up to date")
        }
    }

    private func branchTapped() {
        if canBranch { askingBranch = true }
        else if !workspace.hasLocalRepo { report("branch: no local git repo") }
        else { report("branch: no commits yet — commit first") }
    }

    private func mergeTapped() {
        if canMerge { askingMerge = true }
        else if !workspace.hasLocalRepo { report("merge: no local git repo") }
        else { report("merge: only one branch") }
    }

    /// Always usable: re-derive the toolbar's enablement, re-check the remote head, rebuild
    /// the graph. The one control whose prerequisite is just "a workspace exists".
    private func refreshTapped() {
        guard !refreshing else { return }
        refreshing = true
        Task {
            await workspace.refreshAll(token: GitHubAuth.shared.accessToken)
            refreshing = false
        }
    }

    // MARK: - Actions

    private func commit() {
        let message = commitMessage.isEmpty ? "Update from Mouse" : commitMessage
        do {
            _ = try GitCore.commitAll(in: workspace.root, message: message)
            workspace.clearModified()
            FileBuffer.rebaseline(for: workspace)
            workspace.localHistoryChanged()
        } catch {
            report("commit: \(error)")
        }
    }

    private func switchBranch(_ name: String) {
        do {
            try GitCore.checkout(name, in: workspace.root)
            workspace.clearModified()
            workspace.treeVersion += 1          // worktree replaced — file views reload
            workspace.localHistoryChanged()
        } catch {
            report("branch: \(error)")
        }
    }

    private func createBranch() {
        let name = newBranchName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        do {
            try GitCore.createBranch(name, in: workspace.root)
            try GitCore.checkout(name, in: workspace.root)
            workspace.localHistoryChanged()
        } catch {
            report("branch: \(error)")
        }
    }

    private func merge(_ name: String) {
        do {
            let result = try GitCore.merge(name, in: workspace.root)
            switch result {
            case .upToDate:
                report("merge: already up to date", isError: false)
            case .fastForward:
                report("merge: fast-forwarded \(workspace.currentGitBranch) to \(name)", isError: false)
                workspace.treeVersion += 1
                workspace.localHistoryChanged()
            case .merged:
                report("merge: made a merge commit of \(name)", isError: false)
                workspace.treeVersion += 1
                workspace.localHistoryChanged()
            case .conflicts(let files):
                report("merge: conflicts in \(files.joined(separator: ", ")) — resolve the markers and commit")
                workspace.treeVersion += 1       // worktree now holds conflict markers
                files.forEach { workspace.markModified($0) }
                workspace.refreshGitState()
            }
        } catch {
            report("merge: \(error)")
        }
    }

    /// Sync's native path: PUSH local commits (creating the GitHub repo on first push). Sync
    /// never pulls — the app must not rewrite a user's files on its own; bringing down remote
    /// commits is the explicit `git pull` in the terminal (which refuses over uncommitted edits).
    private func gitPush() {
        guard let token = GitHubAuth.shared.accessToken, let login = signedInLogin else { return }
        let branch = GitCore.currentBranch(in: workspace.root) ?? "main"
        let repoName = workspace.gitRemoteRepoName(login: login)
        workspace.pushState = .pushing
        Task {
            do {
                let result = try await GitRemote.push(root: workspace.root, repoFullName: repoName,
                                                      branch: branch, token: token, login: login)
                workspace.pushState = .idle
                workspace.localHistoryChanged()
                var notes: [String] = []
                if result.createdRepo { notes.append("created \(repoName)") }
                notes.append(result.objectCount == 0 ? "up to date"
                    : "pushed \(result.objectCount) object\(result.objectCount == 1 ? "" : "s")")
                report("sync: \(notes.joined(separator: ", "))", isError: false)
            } catch {
                syncFailed("sync", error)
            }
        }
    }

    /// Sync's Data-API push for downloaded (tarball) repos: commit the modified files via the
    /// GitHub contents API.
    private func dataPush() {
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
                    repo: workspace.repoFullName, root: workspace.root,
                    paths: paths, message: message, token: token)
                workspace.clearModified()
                workspace.markSynced(to: commitSha)
                FileBuffer.rebaseline(for: workspace)
                workspace.pushState = .idle
                await workspace.refreshHistory(token: token)
            } catch {
                syncFailed("sync", error)
            }
        }
    }

    /// Sync's Data-API pull for downloaded repos: replace the working tree with the latest tarball.
    private func dataPull() {
        guard let token = GitHubAuth.shared.accessToken else { return }
        workspace.pushState = .pushing
        Task {
            do {
                try await Workspace.fetchAndExtract(workspace.repoFullName, token: token)
                let sha = try? await Workspace.remoteHeadSha(workspace.repoFullName, token: token)
                workspace.markSynced(to: sha)
                workspace.clearModified()
                workspace.treeVersion += 1
                workspace.pushState = .idle
                await workspace.refreshHistory(token: token)
            } catch {
                syncFailed("sync", error)
            }
        }
    }

    // MARK: - Reporting

    /// A failed sync's reason lands in the terminal (readable, scrollable, permanent); the button
    /// flashes via `.failed` then returns to actionable — a stuck error state tells you nothing.
    private func syncFailed(_ what: String, _ error: Error) {
        report("\(what): \(error)")
        workspace.pushState = .failed("\(error)")
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.6))
            if case .failed = workspace.pushState { workspace.pushState = .idle }
        }
    }

    private func report(_ text: String, isError: Bool = true) {
        deck.terminal(for: workspace).report(text, isError: isError)
    }

    private func isBusy(_ state: Workspace.PushState) -> Bool {
        if case .pushing = state { return true }
        return false
    }
    private func isFailed(_ state: Workspace.PushState) -> Bool {
        if case .failed = state { return true }
        return false
    }

    private var syncPushTitle: String {
        let count = workspace.modifiedPaths.count
        return "Commit \(count) file\(count == 1 ? "" : "s") to \(workspace.repoFullName)"
    }

    // MARK: - Control

    /// One labeled control: mono text, full white when usable, dimmed when not. Always tappable
    /// (a dimmed tap explains itself). Only sync passes `busy`/`failed` — a spinner while it runs,
    /// a red tint on failure — since it's the only control with in-flight state.
    private func control(_ label: String, enabled: Bool, busy: Bool = false, failed: Bool = false,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Text(label)
                    .font(.custom(AppFont.asciiName, size: 12))
                    .foregroundStyle(failed ? .red : .white.opacity(enabled ? 0.85 : 0.28))
                    .opacity(busy ? 0 : 1)
                if busy {
                    ProgressView().tint(.white).scaleEffect(0.5)
                }
            }
            .padding(.vertical, 6)          // taller hit area than the 12pt glyph
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
