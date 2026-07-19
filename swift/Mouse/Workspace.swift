import Foundation
import Compression

/// A project: a working tree on local disk plus the shared project state (dirty set, sync
/// state, graph cache). One instance per repo, app-wide — rings VIEW workspaces; per-ring
/// viewport state (open file, terminal session) lives on `CarouselDeck`.
///
/// Phase 1 acquires the working tree from GitHub's tarball API (authenticated by `GitHubAuth`) and
/// extracts it natively — no git binary dependency yet. The Source Control phase brings libgit2,
/// which takes over acquisition (real clones) without changing this model's shape. The gunzip/tar
/// code here is shared infrastructure: the package manager (`pnpm install`) uses the same path.
@Observable
final class Workspace {
    let repoFullName: String
    let root: URL
    /// Relative paths edited locally since the last successful push — the prerequisite that
    /// surfaces the push action in the containers' top-right icon row. Persisted.
    private(set) var modifiedPaths: Set<String> = []
    /// The push action's in-flight state (never persisted).
    var pushState: PushState = .idle
    /// The pull action's in-flight state (never persisted).
    var pullState: PushState = .idle
    /// Bumped when the working tree is replaced wholesale (a pull), so file views reload.
    var treeVersion = 0
    /// Commit-graph data, loaded in the background (fully off screen) so the Graph container
    /// renders instantly on swipe-in. Refreshed when the tree or the synced head changes.
    private(set) var graphRows: [GraphRow]?
    private(set) var graphTips: [String: String] = [:]
    private(set) var graphError: String?
    private var historyStamp: String?
    private var historyInFlight = false
    /// The remote head sha the local tree was last synced to (download, pull, or our own push).
    private(set) var syncedSha: String?
    /// True when the remote has commits we haven't pulled — the pull chip's prerequisite.
    private(set) var upstreamAvailable = false
    private var lastUpstreamCheck: Date?

    enum PushState {
        case idle
        case pushing
        case failed(String)
    }

    enum Phase {
        case downloading
        case ready
        case failed(String)
    }

    private(set) var phase: Phase

    var hasChanges: Bool { !modifiedPaths.isEmpty }

    // MARK: - One workspace per repo, shared across rings

    /// One `Workspace` per repo, app-wide: rings that open the same repo hold the SAME object,
    /// so the tree, dirty set, sync state, and graph cache stay in step — while each ring keeps
    /// its own open file and terminal (viewport state, on the deck). Same pattern as
    /// `ContainerContent`'s synced kinds and `GitHubAuth.shared`. Main-thread only.
    nonisolated(unsafe) private static var byRepo: [String: Workspace] = [:]

    /// The shared workspace for a repo: the live instance if any ring already has it, else a
    /// ready one if its tree is on disk from before, else a fresh one awaiting download.
    static func shared(for repoFullName: String) -> Workspace {
        if let live = byRepo[repoFullName] { return live }
        let fresh = Workspace(existing: repoFullName) ?? Workspace(downloading: repoFullName)
        byRepo[repoFullName] = fresh
        return fresh
    }

    /// True for projects born on this device ("local/<name>") — no remote exists, so there is
    /// nothing to push or pull until a publish flow arrives (roadmap).
    var isLocal: Bool { repoFullName.hasPrefix("local/") }

    /// True when the worktree has a real .git (GitCore) — local history exists.
    var hasLocalRepo: Bool { GitCore.hasRepo(root) }

    /// Every local project on disk ("local/<name>"), for the picker.
    static func localProjectNames() -> [String] {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("workspaces")
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? []
        return entries
            .filter { $0.hasPrefix("local__") }
            .map { "local/" + $0.dropFirst("local__".count) }
            .sorted()
    }

    /// Create (or reopen) a fresh local project — code without GitHub: an empty tree under
    /// `local/<name>`, ready immediately. Files come from the editor and the terminal
    /// (`touch`, redirects); persistence and restore work exactly like repo workspaces.
    static func local(named rawName: String) -> Workspace {
        let name = rawName
            .lowercased()
            .map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "-" }
            .reduce(into: "") { if !($0.hasSuffix("-") && $1 == "-") { $0.append($1) } }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let full = "local/" + (name.isEmpty ? "project" : name)
        if let live = byRepo[full] { return live }
        let dir = directory(for: full)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? GitCore.initRepo(dir)
        guard let fresh = Workspace(existing: full) else {
            // Directory creation failed (out of disk?) — surface as a failed workspace.
            let broken = Workspace(downloading: full)
            broken.phase = .failed("couldn't create the project folder")
            byRepo[full] = broken
            return broken
        }
        byRepo[full] = fresh
        return fresh
    }

    /// Restore path: the shared workspace, seeded with persisted state if it isn't live yet
    /// (a second ring restoring the same repo just gets the first ring's instance).
    static func shared(
        existing repoFullName: String,
        modifiedPaths: [String],
        syncedSha: String?
    ) -> Workspace? {
        if let live = byRepo[repoFullName] { return live }
        guard let fresh = Workspace(
            existing: repoFullName,
            modifiedPaths: modifiedPaths,
            syncedSha: syncedSha
        ) else { return nil }
        byRepo[repoFullName] = fresh
        return fresh
    }

    /// True while a tree download is running (a second ring attaching mid-download shares it).
    private(set) var fetchInFlight = false

    /// Download (or retry) the tree into this shared workspace. No-op when already ready or
    /// when a fetch is in flight.
    @MainActor
    func startDownload(token: String) {
        if case .ready = phase { return }
        guard !fetchInFlight else { return }
        fetchInFlight = true
        phase = .downloading
        Task {
            do {
                try await Workspace.fetchAndExtract(repoFullName, token: token)
                let sha = try? await Workspace.remoteHeadSha(repoFullName, token: token)
                markSynced(to: sha)
                phase = .ready
            } catch {
                phase = .failed(error.localizedDescription)
            }
            fetchInFlight = false
        }
    }

    /// The local tree now matches this remote sha; nothing upstream until proven otherwise.
    func markSynced(to sha: String?) {
        syncedSha = sha
        upstreamAvailable = false
        lastUpstreamCheck = nil
    }

    /// Fetch and lay out the commit graph if the cached copy is missing or stale (the tree or
    /// synced head moved since it was built). Runs regardless of whether the Graph is visible.
    @MainActor
    func refreshHistory(token: String?) async {
        let stamp = "\(treeVersion)|\(syncedSha ?? "?")"
        guard !historyInFlight else { return }
        guard historyStamp != stamp || graphRows == nil else { return }
        historyInFlight = true
        defer { historyInFlight = false }

        // A workspace with a real .git (local projects are born with one; repo workspaces get
        // one via `git init`) graphs its LOCAL history — full topology, no network.
        if GitCore.hasRepo(root) {
            let root = self.root
            let local: (rows: [GraphRow], tips: [String: String])? = await Task.detached {
                let branches = GitCore.branches(in: root)
                guard !branches.isEmpty else { return ([], [:]) }
                var seen: Set<String> = []
                var nodes: [CommitNode] = []
                for tip in branches.values {
                    guard let commits = try? GitCore.log(from: tip, in: root) else { continue }
                    for commit in commits where !seen.contains(commit.sha) {
                        seen.insert(commit.sha)
                        nodes.append(CommitNode(
                            sha: commit.sha,
                            message: commit.message.components(separatedBy: "\n")[0],
                            author: commit.author.components(separatedBy: " <")[0],
                            parents: commit.parents
                        ))
                    }
                }
                nodes.sort { a, b in
                    // Parents must come after children for the lane layout; date order works
                    // for our linear-ish histories.
                    guard let ca = try? GitCore.readCommit(a.sha, in: root),
                          let cb = try? GitCore.readCommit(b.sha, in: root) else { return false }
                    return ca.date > cb.date
                }
                var tips: [String: String] = [:]
                for (name, sha) in branches { tips[sha] = name }
                return (GitGraph.layout(nodes), tips)
            }.value
            if let local {
                graphRows = local.rows
                graphTips = local.tips
                graphError = nil
                historyStamp = stamp
            }
            return
        }

        guard !isLocal, let token else { return }
        do {
            let history = try await GitGraph.fetchHistory(repo: repoFullName, token: token)
            graphRows = GitGraph.layout(history.commits)
            graphTips = history.branchTips
            graphError = nil
            historyStamp = stamp
        } catch {
            if graphRows == nil { graphError = error.localizedDescription }
        }
    }

    /// Compare the remote head against `syncedSha` (throttled to once a minute).
    @MainActor
    func refreshUpstream(token: String) async {
        guard !isLocal else { return }
        if let last = lastUpstreamCheck, Date().timeIntervalSince(last) < 60 { return }
        lastUpstreamCheck = Date()
        guard let head = try? await Workspace.remoteHeadSha(repoFullName, token: token) else { return }
        upstreamAvailable = head != syncedSha
    }

    /// The sha of the default branch's latest commit.
    static func remoteHeadSha(_ repoFullName: String, token: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repoFullName)/commits?per_page=1")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw TarGz.ExtractError("GitHub returned \(http.statusCode) checking the remote head")
        }
        guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let sha = list.first?["sha"] as? String else {
            throw TarGz.ExtractError("couldn't read the remote head")
        }
        return sha
    }

    /// The worktree was rewritten outside the viewers (a `git checkout`): reload file views.
    func bumpTreeVersion() { treeVersion += 1 }

    /// True when the local git repo has commits the remote doesn't (never pushed, or ahead).
    /// A sync prerequisite. Recomputed by `refreshGitState`, so it stays reactive.
    var unpushedCommits = false
    /// The branch the toolbar operates on (for confirm text and the branch label).
    var currentGitBranch = "main"
    /// True when the worktree differs from HEAD — the commit button's prerequisite.
    var hasUncommittedChanges = false
    /// True once the current branch has at least one commit (branch/merge need a base commit).
    var hasCommits = false
    /// Local branch names, sorted — merge lights up at two or more.
    var localBranches: [String] = []

    /// Refresh the git-derived toolbar state from disk (after commit/checkout/merge/push, or on
    /// ready). Cheap enough for a local tree; `status` hashes files but the trees are small.
    func refreshGitState() {
        guard GitCore.hasRepo(root) else {
            unpushedCommits = false; hasUncommittedChanges = false; hasCommits = false; localBranches = []
            return
        }
        let branch = GitCore.currentBranch(in: root) ?? "main"
        currentGitBranch = branch
        localBranches = GitCore.branches(in: root).keys.sorted()
        guard let localSha = GitCore.refSha(branch, in: root) else {
            unpushedCommits = false; hasUncommittedChanges = false; hasCommits = false
            return
        }
        hasCommits = true
        unpushedCommits = GitCore.remoteTrackingSha(branch: branch, in: root) != localSha
        hasUncommittedChanges = ((try? GitCore.status(in: root))?.isClean == false)
    }

    /// The "owner/name" this project pushes to: an existing origin, else the signed-in user's
    /// account with the project's own name (which push auto-creates).
    func gitRemoteRepoName(login: String) -> String {
        if let url = GitCore.remoteURL(in: root) {
            var name = url
            if let range = name.range(of: "github.com/") { name = String(name[range.upperBound...]) }
            if name.hasSuffix(".git") { name = String(name.dropLast(4)) }
            return name
        }
        let leaf = root.lastPathComponent.replacingOccurrences(of: "local__", with: "")
        return "\(login)/\(leaf)"
    }

    /// Local git history changed (commit, branch, checkout, push): rebuild the graph and the
    /// git slot state.
    @MainActor
    func localHistoryChanged() {
        historyStamp = nil
        refreshGitState()
        Task { @MainActor [weak self] in
            await self?.refreshHistory(token: nil)
        }
    }

    func markModified(_ path: String) { modifiedPaths.insert(path) }
    func unmarkModified(_ path: String) { modifiedPaths.remove(path) }
    func clearModified() { modifiedPaths = [] }

    /// Reopen an already-downloaded workspace. Fails if the tree is gone. Private: all creation
    /// goes through the shared registry above.
    private init?(existing repoFullName: String, modifiedPaths: [String] = [], syncedSha: String? = nil) {
        let dir = Self.directory(for: repoFullName)
        guard FileManager.default.fileExists(atPath: dir.path) else { return nil }
        self.repoFullName = repoFullName
        self.root = dir
        self.modifiedPaths = Set(modifiedPaths)
        self.syncedSha = syncedSha
        self.phase = .ready
        refreshGitState()   // so the push slot reflects unpushed commits from the first frame
    }

    /// A workspace awaiting download. Private: all creation goes through the shared registry.
    private init(downloading repoFullName: String) {
        self.repoFullName = repoFullName
        self.root = Self.directory(for: repoFullName)
        self.phase = .downloading
    }

    static func directory(for repoFullName: String) -> URL {
        let safe = repoFullName.replacingOccurrences(of: "/", with: "__")
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("workspaces", isDirectory: true)
            .appendingPathComponent(safe, isDirectory: true)
    }

    /// Fetch the repo's tarball and extract it into the workspace directory (replacing whatever
    /// was there). Pure and nonisolated — runs off the main actor; callers update `phase`.
    static func fetchAndExtract(_ repoFullName: String, token: String) async throws {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repoFullName)/tarball")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw TarGz.ExtractError("GitHub returned \(http.statusCode) for the download")
        }
        let dir = directory(for: repoFullName)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // GitHub tarballs wrap everything in a single "owner-repo-sha/" directory — strip it.
        try TarGz.extract(data, into: dir, stripComponents: 1)
    }
}

/// A repository the signed-in user can open, from `GET /user/repos`.
struct RepoSummary: Decodable, Identifiable, Sendable {
    let fullName: String
    let description: String?
    var id: String { fullName }

    static func fetchMine(token: String) async throws -> [RepoSummary] {
        var request = URLRequest(url: URL(string: "https://api.github.com/user/repos?per_page=100&sort=pushed")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw TarGz.ExtractError("GitHub returned \(http.statusCode) listing repos")
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode([RepoSummary].self, from: data)
    }
}

/// Native .tar.gz extraction: gzip via the Compression framework, tar parsed by hand (ustar +
/// GNU longname + pax path records — enough for GitHub tarballs and npm registry tarballs).
enum TarGz {
    struct ExtractError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    static func extract(_ tgz: Data, into destination: URL, stripComponents: Int = 0) throws {
        let tar = try gunzip(tgz)
        let fm = FileManager.default
        var offset = 0
        var pendingLongName: String?
        var pendingPaxPath: String?

        while offset + 512 <= tar.count {
            let header = tar.subdata(in: offset..<(offset + 512))
            offset += 512
            if header.allSatisfy({ $0 == 0 }) { continue }  // end-of-archive padding

            let size = numeric(header, 124, 12)
            let typeflag = header[156]
            var name = field(header, 0, 100)
            let prefix = field(header, 345, 155)
            if !prefix.isEmpty { name = prefix + "/" + name }
            if let long = pendingLongName { name = long; pendingLongName = nil }
            if let pax = pendingPaxPath { name = pax; pendingPaxPath = nil }

            let content = size > 0 ? tar.subdata(in: offset..<min(offset + size, tar.count)) : Data()
            offset += (size + 511) / 512 * 512

            switch typeflag {
            case UInt8(ascii: "L"):  // GNU long name: content is the next entry's path
                pendingLongName = String(decoding: content, as: UTF8.self)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
                continue
            case UInt8(ascii: "x"):  // pax extended header: may override the next entry's path
                pendingPaxPath = paxValue(content, key: "path")
                continue
            case UInt8(ascii: "g"):  // pax global header: ignore
                continue
            default:
                break
            }

            var components = name.split(separator: "/").map(String.init)
            guard components.count > stripComponents else { continue }
            components.removeFirst(stripComponents)
            // Never let an archive write outside the destination.
            guard !components.contains(".."), !components.isEmpty else { continue }
            let target = components.reduce(destination) { $0.appendingPathComponent($1) }

            switch typeflag {
            case UInt8(ascii: "5"):
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
            case 0, UInt8(ascii: "0"), UInt8(ascii: "7"):
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try content.write(to: target)
            case UInt8(ascii: "2"):
                let linkTarget = field(header, 157, 100)
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.removeItem(at: target)
                try? fm.createSymbolicLink(atPath: target.path, withDestinationPath: linkTarget)
            default:
                break  // hardlinks, fifos, devices: skip
            }
        }
    }

    /// NUL-terminated fixed-width text field.
    private static func field(_ header: Data, _ start: Int, _ len: Int) -> String {
        var bytes: [UInt8] = []
        for i in start..<(start + len) {
            let c = header[i]
            if c == 0 { break }
            bytes.append(c)
        }
        return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
    }

    /// Octal size field, with GNU base-256 fallback for huge entries.
    private static func numeric(_ header: Data, _ start: Int, _ len: Int) -> Int {
        if header[start] & 0x80 != 0 {
            var value = 0
            for i in 1..<len { value = value << 8 | Int(header[start + i]) }
            return value
        }
        var value = 0
        for i in start..<(start + len) {
            let c = header[i]
            if c >= 0x30 && c <= 0x37 { value = value * 8 + Int(c - 0x30) }
            else if value > 0 { break }
        }
        return value
    }

    /// Parse a pax record stream ("<len> <key>=<value>\n"...) for one key.
    private static func paxValue(_ content: Data, key: String) -> String? {
        guard let text = String(data: content, encoding: .utf8) else { return nil }
        var rest = Substring(text)
        while let space = rest.firstIndex(of: " ") {
            guard let length = Int(rest[..<space]), length > 0,
                  let end = rest.index(rest.startIndex, offsetBy: length, limitedBy: rest.endIndex)
            else { return nil }
            let record = rest[rest.index(after: space)..<end].dropLast()  // trailing \n
            if record.hasPrefix("\(key)=") { return String(record.dropFirst(key.count + 1)) }
            rest = rest[end...]
        }
        return nil
    }

    /// Decode a gzip member: parse the header by hand, inflate the raw DEFLATE payload via the
    /// Compression framework (its ZLIB mode is raw DEFLATE, which is exactly gzip's payload).
    static func gunzip(_ data: Data) throws -> Data {
        guard data.count > 18, data[0] == 0x1f, data[1] == 0x8b, data[2] == 8 else {
            throw ExtractError("not a gzip archive")
        }
        let flags = data[3]
        var idx = 10
        if flags & 0x04 != 0 {  // FEXTRA
            let xlen = Int(data[idx]) | (Int(data[idx + 1]) << 8)
            idx += 2 + xlen
        }
        if flags & 0x08 != 0 { while idx < data.count, data[idx] != 0 { idx += 1 }; idx += 1 }  // FNAME
        if flags & 0x10 != 0 { while idx < data.count, data[idx] != 0 { idx += 1 }; idx += 1 }  // FCOMMENT
        if flags & 0x02 != 0 { idx += 2 }  // FHCRC
        guard idx < data.count else { throw ExtractError("truncated gzip archive") }
        return try inflate(data.subdata(in: idx..<data.count))
    }

    private static func inflate(_ input: Data) throws -> Data {
        let streamPointer = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { streamPointer.deallocate() }
        guard compression_stream_init(streamPointer, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw ExtractError("couldn't start the decompressor")
        }
        defer { compression_stream_destroy(streamPointer) }

        let chunkSize = 1 << 17
        let chunk = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
        defer { chunk.deallocate() }

        var output = Data()
        try input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else {
                throw ExtractError("empty archive")
            }
            streamPointer.pointee.src_ptr = base
            streamPointer.pointee.src_size = raw.count
            while true {
                streamPointer.pointee.dst_ptr = chunk
                streamPointer.pointee.dst_size = chunkSize
                let status = compression_stream_process(streamPointer, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                output.append(chunk, count: chunkSize - streamPointer.pointee.dst_size)
                if status == COMPRESSION_STATUS_END { break }
                guard status == COMPRESSION_STATUS_OK else { throw ExtractError("corrupt archive") }
            }
        }
        return output
    }
}
