import Foundation

/// The remote half of the native git engine: clone, fetch, and push over GitHub's smart-HTTP
/// protocol, on top of `GitCore`'s object store and packfile codec. No libgit2, no binaries.
///
/// The star capability is **push that creates the repo for you**: if the target repository
/// doesn't exist, `push` calls `POST /user/repos` first, so you never open github.com to make
/// an empty repo. Local projects (`local/<name>`) publish under the signed-in user's account.
///
/// Auth is HTTP Basic with the token as the password (GitHub's git-over-HTTPS convention).
enum GitRemote {

    struct RemoteError: Error, CustomStringConvertible {
        let message: String
        init(_ message: String) { self.message = message }
        var description: String { message }
    }

    /// The GitHub HTTPS URL for a repo, e.g. "owner/name" → https://github.com/owner/name.git
    static func url(for repoFullName: String) -> String {
        "https://github.com/\(repoFullName).git"
    }

    // MARK: - Ref discovery (GET /info/refs?service=…)

    struct Advertised {
        /// refname → sha (e.g. "refs/heads/main" → sha). Empty for a brand-new repo.
        let refs: [String: String]
        let capabilities: [String]
        var headBranch: String?   // from the symref capability, when present
    }

    /// Discover a repo's advertised refs, or nil when the repo doesn't exist (404).
    private static func discover(service: String, repoFullName: String, token: String) async throws -> Advertised? {
        var request = URLRequest(url: URL(string: "\(url(for: repoFullName))/info/refs?service=\(service)")!)
        request.setValue(basicAuth(token), forHTTPHeaderField: "Authorization")
        request.setValue("application/x-\(service)-advertisement", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 404 { return nil }
        guard code == 200 else { throw RemoteError("git: server returned \(code)") }

        // pkt-lines: "# service=…", flush, then ref lines, flush.
        var refs: [String: String] = [:]
        var capabilities: [String] = []
        var headBranch: String?
        var sawService = false
        for line in GitCore.parsePktLines(data) {
            guard let text = String(data: line, encoding: .utf8)?.trimmingCharacters(in: .newlines), !text.isEmpty else { continue }
            if text.hasPrefix("# service=") { sawService = true; continue }
            guard sawService else { continue }
            // First ref line carries capabilities after a NUL.
            let parts = text.split(separator: "\0", maxSplits: 1).map(String.init)
            let refPart = parts[0]
            if parts.count > 1 {
                capabilities = parts[1].split(separator: " ").map(String.init)
                for cap in capabilities where cap.hasPrefix("symref=HEAD:") {
                    headBranch = String(cap.dropFirst("symref=HEAD:refs/heads/".count))
                }
            }
            let tokens = refPart.split(separator: " ", maxSplits: 1).map(String.init)
            if tokens.count == 2, tokens[1] != "capabilities^{}" {
                refs[tokens[1]] = tokens[0]
            }
        }
        return Advertised(refs: refs, capabilities: capabilities, headBranch: headBranch)
    }

    // MARK: - Push (git-receive-pack), creating the repo if needed

    struct PushResult {
        let branch: String
        let createdRepo: Bool
        let objectCount: Int
    }

    /// Push `branch` to `repoFullName`, creating the GitHub repo first if it doesn't exist.
    /// `login` is the signed-in user (for auto-create ownership and the created repo's name).
    static func push(root: URL, repoFullName: String, branch: String, token: String, login: String,
                     makePrivate: Bool = true) async throws -> PushResult {
        guard let localSha = GitCore.refSha(branch, in: root) else {
            throw RemoteError("git: branch '\(branch)' has no commits")
        }

        var target = repoFullName
        var created = false
        var advertised = try await discover(service: "git-receive-pack", repoFullName: target, token: token)
        if advertised == nil {
            // The repo isn't there: create it under the signed-in user, then re-discover.
            let name = repoFullName.contains("/") ? String(repoFullName.split(separator: "/").last!) : repoFullName
            try await createRepo(name: name, private: makePrivate, token: token)
            target = "\(login)/\(name)"
            created = true
            // GitHub can take a moment to make the empty repo pushable.
            for _ in 0..<10 {
                advertised = try await discover(service: "git-receive-pack", repoFullName: target, token: token)
                if advertised != nil { break }
                try await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        guard let advertised else { throw RemoteError("git: repository unavailable after create") }

        let remoteSha = advertised.refs["refs/heads/\(branch)"] ?? String(repeating: "0", count: 40)
        if remoteSha == localSha {
            GitCore.rememberRemote(branch: branch, sha: localSha, in: root)
            return PushResult(branch: branch, createdRepo: created, objectCount: 0)
        }

        // Objects the server doesn't already have (everything, for a new ref).
        let known = remoteSha.hasPrefix("0000") ? Set<String>() : (try reachableShas(remoteSha, in: root))
        let objects = try GitCore.reachableObjects(from: localSha, in: root, excluding: known)
        let pack = try GitCore.writePackfile(objects)

        // receive-pack request: one update command, flush, then the packfile.
        let command = "\(remoteSha) \(localSha) refs/heads/\(branch)\u{0}report-status\n"
        var body = GitCore.pktLine(command)
        body.append(GitCore.pktFlush)
        body.append(pack)

        var request = URLRequest(url: URL(string: "\(url(for: target))/git-receive-pack")!)
        request.httpMethod = "POST"
        request.setValue(basicAuth(token), forHTTPHeaderField: "Authorization")
        request.setValue("application/x-git-receive-pack-request", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw RemoteError("git: push rejected (\(code))") }
        try checkReportStatus(data)

        try? GitCore.setRemote(url(for: target), in: root)
        GitCore.rememberRemote(branch: branch, sha: localSha, in: root)
        return PushResult(branch: branch, createdRepo: created, objectCount: objects.count)
    }

    /// The report-status response confirms the ref updated; unpack/ng lines are failures.
    private static func checkReportStatus(_ data: Data) throws {
        for line in GitCore.parsePktLines(data) {
            guard let text = String(data: line, encoding: .utf8)?.trimmingCharacters(in: .newlines) else { continue }
            if text.hasPrefix("unpack ") && text != "unpack ok" { throw RemoteError("git: \(text)") }
            if text.hasPrefix("ng ") { throw RemoteError("git: rejected \(text.dropFirst(3))") }
        }
    }

    // MARK: - Clone / fetch (git-upload-pack)

    struct FetchResult {
        let branch: String
        let sha: String
        let objectCount: Int
    }

    /// Clone `repoFullName` into `root` (which must be empty): init, fetch the default branch,
    /// write refs, and materialize the worktree.
    static func clone(into root: URL, repoFullName: String, token: String) async throws -> FetchResult {
        try GitCore.initRepo(root)
        try? GitCore.setRemote(url(for: repoFullName), in: root)
        let result = try await fetch(root: root, repoFullName: repoFullName, token: token, integrate: true)
        return result
    }

    /// Fetch the remote default branch's history into the object store. By default this is a
    /// TRUE fetch: objects land in the store and only refs/remotes/origin/<branch> moves — the
    /// local branch, HEAD, and worktree are untouched (integration is merge's job, per the
    /// gospel). `integrate: true` is the clone path: additionally set the local branch ref +
    /// HEAD and materialize the worktree.
    @discardableResult
    static func fetch(root: URL, repoFullName: String, token: String, integrate: Bool = false) async throws -> FetchResult {
        guard let advertised = try await discover(service: "git-upload-pack", repoFullName: repoFullName, token: token) else {
            throw RemoteError("git: repository not found")
        }
        let branch = advertised.headBranch ?? "main"
        guard let wantSha = advertised.refs["refs/heads/\(branch)"] ?? advertised.refs.values.first else {
            throw RemoteError("git: empty repository")
        }

        // Skip the network when the remote tip is already in our store (we pushed it, or a
        // prior fetch brought it) — only the tracking ref needs to move.
        var count = 0
        if (try? GitCore.readObject(wantSha, in: root)) == nil {
            let body = uploadPackBody(want: wantSha, haves: Array(GitCore.branches(in: root).values))
            var request = URLRequest(url: URL(string: "\(url(for: repoFullName))/git-upload-pack")!)
            request.httpMethod = "POST"
            request.setValue(basicAuth(token), forHTTPHeaderField: "Authorization")
            request.setValue("application/x-git-upload-pack-request", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else { throw RemoteError("git: fetch failed (\(code))") }
            count = try GitCore.readPackfile(extractPack(data), into: root)
        }

        GitCore.rememberRemote(branch: branch, sha: wantSha, in: root)
        if integrate {
            try GitCore.setRef(branch, to: wantSha, in: root)
            try GitCore.setHead(branch: branch, in: root)
            try GitCore.checkout(branch, in: root)
        }
        return FetchResult(branch: branch, sha: wantSha, objectCount: count)
    }

    /// The upload-pack request: want (caps on the first line), flush, our haves, done. Single-
    /// round negotiation: the server ACKs the haves it recognizes and builds the pack against
    /// them, so a fetch transfers only what's new (an empty haves list fetches everything).
    static func uploadPackBody(want: String, haves: [String]) -> Data {
        let caps = "multi_ack_detailed side-band-64k ofs-delta agent=mouse"
        var body = GitCore.pktLine("want \(want) \(caps)\n")
        body.append(GitCore.pktFlush)
        for sha in haves { body.append(GitCore.pktLine("have \(sha)\n")) }
        body.append(GitCore.pktLine("done\n"))
        return body
    }

    /// Extract the packfile from an upload-pack response. Negotiation pkt-lines ("ACK <sha> …",
    /// "NAK") pass through un-banded and are skipped — unambiguous because a side-band channel
    /// byte is 1/2/3, never ASCII 'A'/'N'. Banded lines: 1 = pack data, 2 = progress, 3 = error.
    static func extractPack(_ data: Data) throws -> Data {
        var pack = Data()
        for line in GitCore.parsePktLines(data) {
            guard let channel = line.first else { continue }
            switch channel {
            case 1: pack.append(line.dropFirst())
            case 3: throw RemoteError("git: \(String(data: line.dropFirst(), encoding: .utf8) ?? "remote error")")
            default: break   // 2 = progress; anything else is an ACK/NAK negotiation line
            }
        }
        return pack
    }

    // MARK: - Repo creation (POST /user/repos)

    private static func createRepo(name: String, private isPrivate: Bool, token: String) async throws {
        var request = URLRequest(url: URL(string: "https://api.github.com/user/repos")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "name": name, "private": isPrivate, "auto_init": false,
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 201 else {
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String
            // With `repo` scope a 403 here means a stale token (a GitHub-App-era session, or a
            // revoked grant) — a fresh sign-in mints one that can create repos.
            if code == 403 {
                throw RemoteError("git: GitHub blocked repo creation (403). Sign out and back in, or create \(name) on github.com first, then push.")
            }
            throw RemoteError("git: couldn't create repo\(detail.map { " (\($0))" } ?? "")")
        }
    }

    // MARK: - Helpers

    /// Every object sha reachable from a commit (to tell the server what NOT to send in a pack).
    private static func reachableShas(_ commitSha: String, in root: URL) throws -> Set<String> {
        Set(try GitCore.reachableObjects(from: commitSha, in: root).map { $0.sha })
    }

    private static func basicAuth(_ token: String) -> String {
        "Basic " + Data("x-access-token:\(token)".utf8).base64EncodedString()
    }
}
