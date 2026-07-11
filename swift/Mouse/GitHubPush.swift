import Foundation

/// Commits the workspace's locally edited files back to GitHub as ONE real commit, via the Git
/// Data API — no libgit2, no .git directory needed:
///
///   default branch → head commit → base tree → a blob per edited file → new tree (based on the
///   remote's current tree, so untouched files are preserved) → new commit → fast-forward the ref.
///
/// Files someone else changed remotely stay as they are unless we also edited them (last write
/// wins on exactly the edited paths). When libgit2 arrives, real merge semantics replace this.
enum GitHubPush {
    struct PushError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    @discardableResult
    static func push(repo: String, root: URL, paths: [String], message: String, token: String) async throws -> String {
        let api = "https://api.github.com/repos/\(repo)"

        let repoInfo = try await request("GET", "\(api)", token: token)
        guard let branch = repoInfo["default_branch"] as? String else {
            throw PushError("couldn't determine the default branch")
        }

        let ref = try await request("GET", "\(api)/git/ref/heads/\(branch)", token: token)
        guard let object = ref["object"] as? [String: Any], let headSha = object["sha"] as? String else {
            throw PushError("couldn't read the branch head")
        }

        let headCommit = try await request("GET", "\(api)/git/commits/\(headSha)", token: token)
        guard let headTree = headCommit["tree"] as? [String: Any], let baseTree = headTree["sha"] as? String else {
            throw PushError("couldn't read the head commit")
        }

        var entries: [[String: Any]] = []
        for path in paths.sorted() {
            let fileURL = root.appendingPathComponent(path)
            guard let data = try? Data(contentsOf: fileURL) else {
                continue  // edited then deleted locally; nothing to push for it
            }
            let blob = try await request("POST", "\(api)/git/blobs", token: token, body: [
                "content": data.base64EncodedString(),
                "encoding": "base64",
            ])
            guard let blobSha = blob["sha"] as? String else {
                throw PushError("couldn't upload \(path)")
            }
            entries.append(["path": path, "mode": "100644", "type": "blob", "sha": blobSha])
        }
        guard !entries.isEmpty else { throw PushError("nothing to push") }

        let newTree = try await request("POST", "\(api)/git/trees", token: token, body: [
            "base_tree": baseTree,
            "tree": entries,
        ])
        guard let treeSha = newTree["sha"] as? String else { throw PushError("couldn't build the tree") }

        let newCommit = try await request("POST", "\(api)/git/commits", token: token, body: [
            "message": message,
            "tree": treeSha,
            "parents": [headSha],
        ])
        guard let commitSha = newCommit["sha"] as? String else { throw PushError("couldn't create the commit") }

        _ = try await request("PATCH", "\(api)/git/refs/heads/\(branch)", token: token, body: [
            "sha": commitSha,
        ])
        return commitSha
    }

    private static func request(
        _ method: String,
        _ urlString: String,
        token: String,
        body: [String: Any]? = nil
    ) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: urlString)!)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { $0?["message"] as? String }
            throw PushError("GitHub said \(http.statusCode)\(detail.map { ": \($0)" } ?? "")")
        }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]).flatMap { $0 } ?? [:]
    }
}
