import Compression
import CryptoKit
import Foundation
import zlib

/// A from-scratch git engine, in the house tradition (tar, gzip, ICMP, msh): no libgit2, no
/// binaries. Git's core is an object store — zlib-deflated blobs/trees/commits addressed by
/// SHA-1 — plus refs as plain files. This implements exactly that, writing repositories the
/// real `git` CLI accepts (verified against `git fsck`).
///
/// Scope: local history. init, commit (whole worktree; no index yet), status, log, branch,
/// checkout, and object reads for diff. The remote pack protocol is not built; GitHub sync
/// stays on the Data API slots until it is.
///
/// Everything is synchronous file IO on small trees; callers off the main thread as needed.
enum GitCore {

    struct GitError: Error, CustomStringConvertible {
        let message: String
        init(_ message: String) { self.message = message }
        var description: String { message }
    }

    // MARK: - Repository layout

    static func gitDirectory(_ root: URL) -> URL { root.appendingPathComponent(".git") }

    static func hasRepo(_ root: URL) -> Bool {
        FileManager.default.fileExists(atPath: gitDirectory(root).appendingPathComponent("HEAD").path)
    }

    /// `git init`: the minimal skeleton the real git accepts.
    static func initRepo(_ root: URL) throws {
        let git = gitDirectory(root)
        guard !hasRepo(root) else { throw GitError("already a git repository") }
        let fm = FileManager.default
        try fm.createDirectory(at: git.appendingPathComponent("objects"), withIntermediateDirectories: true)
        try fm.createDirectory(at: git.appendingPathComponent("refs/heads"), withIntermediateDirectories: true)
        try "ref: refs/heads/main\n".write(to: git.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        try "[core]\n\trepositoryformatversion = 0\n\tfilemode = false\n\tbare = false\n"
            .write(to: git.appendingPathComponent("config"), atomically: true, encoding: .utf8)
    }

    // MARK: - Object store (loose objects)

    enum ObjectType: String {
        case blob, tree, commit
    }

    /// SHA-1 of "<type> <size>\0<content>" — git's object id.
    static func hashObject(_ type: ObjectType, _ content: Data) -> String {
        var data = Data("\(type.rawValue) \(content.count)\0".utf8)
        data.append(content)
        return Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Write a loose object (zlib-wrapped deflate at objects/aa/bb…); returns its sha.
    @discardableResult
    static func writeObject(_ type: ObjectType, _ content: Data, in root: URL) throws -> String {
        let sha = hashObject(type, content)
        let dir = gitDirectory(root).appendingPathComponent("objects/\(sha.prefix(2))")
        let file = dir.appendingPathComponent(String(sha.dropFirst(2)))
        guard !FileManager.default.fileExists(atPath: file.path) else { return sha }
        var payload = Data("\(type.rawValue) \(content.count)\0".utf8)
        payload.append(content)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try zlibCompress(payload).write(to: file)
        return sha
    }

    private static let importedPacksLock = NSLock()
    /// Packfiles already exploded into the loose store, by path. A walk asks for the same absent
    /// object once per branch, and importing a pack repeatedly would be pure waste.
    nonisolated(unsafe) private static var importedPacks: Set<String> = []

    /// Explode any packfile not yet imported into the loose store, so the reader below can find
    /// what is in it. This store is loose-only by design — `readPackfile` is how a fetched pack
    /// has always entered it — but a repository CLONED by real git keeps its objects packed, and
    /// nothing ever imported those. In this checkout that was 125 objects, one of them the merge
    /// commit every branch passes through, so every history stopped dead at the same place.
    /// Returns true when something new was imported and a retry is worth it.
    private static func importPacks(in root: URL) -> Bool {
        let packDir = gitDirectory(root).appendingPathComponent("objects/pack")
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: packDir.path)) ?? [])
            .filter { $0.hasSuffix(".pack") }.sorted()
        var imported = false
        for name in names {
            let file = packDir.appendingPathComponent(name)
            importedPacksLock.lock()
            let already = importedPacks.contains(file.path)
            if !already { importedPacks.insert(file.path) }
            importedPacksLock.unlock()
            if already { continue }
            guard let data = try? Data(contentsOf: file) else { continue }
            // A pack we cannot read is not a reason to fail the read that asked for it: the
            // object may be loose, or in the next pack.
            if (try? readPackfile(data, into: root)) != nil { imported = true }
        }
        return imported
    }

    /// Read an object by sha. Loose first; a miss imports any packfile that has not been
    /// exploded yet and looks again.
    static func readObject(_ sha: String, in root: URL) throws -> (type: ObjectType, content: Data) {
        let file = gitDirectory(root)
            .appendingPathComponent("objects/\(sha.prefix(2))/\(sha.dropFirst(2))")
        var loose = try? Data(contentsOf: file)
        if loose == nil, importPacks(in: root) { loose = try? Data(contentsOf: file) }
        guard let compressed = loose else {
            throw GitError("object not found: \(sha)")
        }
        let payload = try zlibDecompress(compressed)
        guard let zero = payload.firstIndex(of: 0),
              let header = String(data: payload[payload.startIndex..<zero], encoding: .utf8) else {
            throw GitError("corrupt object: \(sha)")
        }
        let pieces = header.split(separator: " ")
        guard pieces.count == 2, let type = ObjectType(rawValue: String(pieces[0])) else {
            throw GitError("unknown object type: \(header)")
        }
        return (type, Data(payload[payload.index(after: zero)...]))
    }

    // MARK: - Trees

    struct TreeEntry {
        let mode: String   // "100644" file, "40000" tree
        let name: String
        let sha: String
        var isTree: Bool { mode == "40000" }
    }

    /// Build tree objects for a worktree directory (recursively) and return the root tree sha.
    /// `.git` is skipped; empty directories vanish (as in real git).
    static func writeTree(for directory: URL, root: URL) throws -> String {
        let fm = FileManager.default
        var entries: [TreeEntry] = []
        let children = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for child in children {
            let name = child.lastPathComponent
            if name == ".git" { continue }
            let isDirectory = (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDirectory {
                let sha = try writeTree(for: child, root: root)
                // An empty subtree writes the empty-tree object; include it anyway for
                // simplicity (git tolerates it, and our workspaces rarely have empty dirs).
                entries.append(TreeEntry(mode: "40000", name: name, sha: sha))
            } else {
                let data = try Data(contentsOf: child)
                let sha = try writeObject(.blob, data, in: root)
                entries.append(TreeEntry(mode: "100644", name: name, sha: sha))
            }
        }
        return try writeObject(.tree, serializeTree(entries), in: root)
    }

    /// Git's tree sort: byte order, with directory names compared as if they end in "/".
    private static func serializeTree(_ entries: [TreeEntry]) -> Data {
        let sorted = entries.sorted { a, b in
            let ka = a.name + (a.isTree ? "/" : "")
            let kb = b.name + (b.isTree ? "/" : "")
            return ka.utf8.lexicographicallyPrecedes(kb.utf8) { $0 < $1 }
        }
        var data = Data()
        for entry in sorted {
            data.append(Data("\(entry.mode) \(entry.name)\0".utf8))
            data.append(shaToRaw(entry.sha))
        }
        return data
    }

    static func parseTree(_ content: Data) -> [TreeEntry] {
        var entries: [TreeEntry] = []
        var index = content.startIndex
        while index < content.endIndex {
            guard let space = content[index...].firstIndex(of: 0x20),
                  let zero = content[space...].firstIndex(of: 0) else { break }
            let mode = String(data: content[index..<space], encoding: .utf8) ?? ""
            let name = String(data: content[content.index(after: space)..<zero], encoding: .utf8) ?? ""
            let shaStart = content.index(after: zero)
            guard let shaEnd = content.index(shaStart, offsetBy: 20, limitedBy: content.endIndex) else { break }
            let sha = content[shaStart..<shaEnd].map { String(format: "%02x", $0) }.joined()
            entries.append(TreeEntry(mode: mode, name: name, sha: sha))
            index = shaEnd
        }
        return entries
    }

    /// Flatten a tree object into path → blob sha.
    static func flattenTree(_ treeSha: String, prefix: String = "", in root: URL) throws -> [String: String] {
        var files: [String: String] = [:]
        let (type, content) = try readObject(treeSha, in: root)
        guard type == .tree else { throw GitError("not a tree: \(treeSha)") }
        for entry in parseTree(content) {
            let path = prefix.isEmpty ? entry.name : "\(prefix)/\(entry.name)"
            if entry.isTree {
                files.merge(try flattenTree(entry.sha, prefix: path, in: root)) { a, _ in a }
            } else {
                files[path] = entry.sha
            }
        }
        return files
    }

    // MARK: - Commits

    struct Commit {
        let sha: String
        let tree: String
        let parents: [String]
        let author: String
        let date: Date
        let message: String
    }

    /// Commit the whole worktree (no index yet: what's on disk is what's committed).
    /// Returns the new commit sha, or throws "nothing to commit" when the tree is unchanged.
    static func commitAll(in root: URL, message: String, author: String = "mouse <mouse@local>") throws -> String {
        let treeSha = try writeTree(for: root, root: root)
        let parent = try? headCommit(in: root)
        if let parent, parent.tree == treeSha {
            throw GitError("nothing to commit")
        }
        let timestamp = Int(Date().timeIntervalSince1970)
        let zone = "+0000"
        var body = "tree \(treeSha)\n"
        if let parent { body += "parent \(parent.sha)\n" }
        body += "author \(author) \(timestamp) \(zone)\n"
        body += "committer \(author) \(timestamp) \(zone)\n"
        body += "\n\(message)\n"
        let sha = try writeObject(.commit, Data(body.utf8), in: root)
        try updateHead(to: sha, in: root)
        try? writeIndex(tree: treeSha, in: root)
        return sha
    }

    static func readCommit(_ sha: String, in root: URL) throws -> Commit {
        let (type, content) = try readObject(sha, in: root)
        guard type == .commit, let text = String(data: content, encoding: .utf8) else {
            throw GitError("not a commit: \(sha)")
        }
        var tree = ""
        var parents: [String] = []
        var author = ""
        var date = Date(timeIntervalSince1970: 0)
        var message = ""
        var inBody = false
        for line in text.components(separatedBy: "\n") {
            if inBody {
                message += message.isEmpty ? line : "\n\(line)"
            } else if line.isEmpty {
                inBody = true
            } else if line.hasPrefix("tree ") {
                tree = String(line.dropFirst(5))
            } else if line.hasPrefix("parent ") {
                parents.append(String(line.dropFirst(7)))
            } else if line.hasPrefix("author ") {
                let pieces = line.dropFirst(7).split(separator: " ")
                if pieces.count >= 3, let timestamp = TimeInterval(pieces[pieces.count - 2]) {
                    date = Date(timeIntervalSince1970: timestamp)
                    author = pieces.dropLast(2).joined(separator: " ")
                }
            }
        }
        return Commit(sha: sha, tree: tree, parents: parents, author: author, date: date,
                      message: message.hasSuffix("\n") ? String(message.dropLast()) : message)
    }

    /// History from a commit, newest first, first-parent plus merged parents (breadth-first).
    /// History from a tip, newest first. `limit` bounds the walk; the default suits a listing
    /// like `git log`, and a caller that wants the whole history says so.
    ///
    /// An unreadable ANCESTOR ends the walk instead of throwing. A history can legitimately stop
    /// short — a shallow clone has a boundary, and this reader only knows loose objects, so a
    /// packed ancestor is simply absent. Throwing lost the whole branch over one missing commit:
    /// the graph's `try?` turned 316 readable commits into none, and RAISING the limit made it
    /// worse, because a shorter walk stopped before reaching the gap. The starting commit still
    /// throws — asking for the history of something unreadable is a real error.
    static func log(from sha: String, in root: URL, limit: Int = 200) throws -> [Commit] {
        var seen: Set<String> = []
        var queue = [sha]
        var commits: [Commit] = []
        while let next = queue.first, commits.count < limit {
            queue.removeFirst()
            guard !seen.contains(next) else { continue }
            seen.insert(next)
            guard let commit = try? readCommit(next, in: root) else {
                if commits.isEmpty { throw GitError("object not found: \(next)") }
                continue
            }
            commits.append(commit)
            queue.append(contentsOf: commit.parents)
        }
        return commits.sorted { $0.date > $1.date }
    }

    // MARK: - Refs

    /// The current branch name from HEAD ("main"), or nil when detached.
    static func currentBranch(in root: URL) -> String? {
        guard let head = try? String(contentsOf: gitDirectory(root).appendingPathComponent("HEAD"), encoding: .utf8) else { return nil }
        let trimmed = head.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("ref: refs/heads/") else { return nil }
        return String(trimmed.dropFirst("ref: refs/heads/".count))
    }

    /// All branches with their tip shas.
    static func branches(in root: URL) -> [String: String] {
        let git = gitDirectory(root)
        let dir = git.appendingPathComponent("refs/heads")
        var result: [String: String] = [:]
        // A branch name with a slash is a DIRECTORY under refs/heads, so a flat listing sees
        // `fix` and not `fix/graph-mount`. Ten of this repository's twenty-one branches are
        // namespaced that way, including the one checked out, and the graph knew about none of
        // them. Walk the tree.
        if let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isDirectoryKey]) {
            for case let file as URL in walker {
                guard (try? file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == false,
                      let sha = try? String(contentsOf: file, encoding: .utf8) else { continue }
                let name = file.path.hasPrefix(dir.path + "/")
                    ? String(file.path.dropFirst(dir.path.count + 1)) : file.lastPathComponent
                result[name] = sha.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        // Refs a real git packs away. `git pack-refs` empties the directories above and moves
        // every ref into this one file, so a cloned repository can have no loose refs at all —
        // the same shape of gap as objects living only in a packfile.
        if let text = try? String(contentsOf: git.appendingPathComponent("packed-refs"), encoding: .utf8) {
            for line in text.split(separator: "\n") {
                guard !line.hasPrefix("#"), !line.hasPrefix("^") else { continue }
                let parts = line.split(separator: " ", maxSplits: 1)
                guard parts.count == 2 else { continue }
                let ref = parts[1].trimmingCharacters(in: .whitespaces)
                guard ref.hasPrefix("refs/heads/") else { continue }
                let name = String(ref.dropFirst("refs/heads/".count))
                // A loose ref WINS: it is the newer value when both exist.
                if result[name] == nil { result[name] = String(parts[0]) }
            }
        }
        return result
    }

    /// The commit HEAD points at, or throws when the branch has no commits yet.
    static func headCommit(in root: URL) throws -> Commit {
        guard let branch = currentBranch(in: root) else { throw GitError("detached HEAD") }
        let ref = gitDirectory(root).appendingPathComponent("refs/heads/\(branch)")
        guard let sha = try? String(contentsOf: ref, encoding: .utf8) else {
            throw GitError("no commits yet")
        }
        return try readCommit(sha.trimmingCharacters(in: .whitespacesAndNewlines), in: root)
    }

    private static func updateHead(to sha: String, in root: URL) throws {
        guard let branch = currentBranch(in: root) else { throw GitError("detached HEAD") }
        let ref = gitDirectory(root).appendingPathComponent("refs/heads/\(branch)")
        try FileManager.default.createDirectory(at: ref.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (sha + "\n").write(to: ref, atomically: true, encoding: .utf8)
    }

    /// Create a branch at the current HEAD commit.
    static func createBranch(_ name: String, in root: URL) throws {
        let head = try headCommit(in: root)
        let ref = gitDirectory(root).appendingPathComponent("refs/heads/\(name)")
        guard !FileManager.default.fileExists(atPath: ref.path) else {
            throw GitError("branch exists: \(name)")
        }
        try (head.sha + "\n").write(to: ref, atomically: true, encoding: .utf8)
    }

    /// Switch branches: point HEAD at the branch and materialize its tree in the worktree.
    /// Tracked files not in the target are removed; untracked files are left alone.
    static func checkout(_ name: String, in root: URL) throws {
        let all = branches(in: root)
        guard let targetSha = all[name] else { throw GitError("no such branch: \(name)") }
        let currentFiles: [String: String]
        if let head = try? headCommit(in: root) {
            currentFiles = try flattenTree(head.tree, in: root)
        } else {
            currentFiles = [:]
        }
        let target = try readCommit(targetSha, in: root)
        let targetFiles = try flattenTree(target.tree, in: root)

        let fm = FileManager.default
        for (path, _) in currentFiles where targetFiles[path] == nil {
            try? fm.removeItem(at: root.appendingPathComponent(path))
        }
        for (path, sha) in targetFiles {
            let url = root.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let (_, content) = try readObject(sha, in: root)
            try content.write(to: url)
        }
        try "ref: refs/heads/\(name)\n".write(to: gitDirectory(root).appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        try? writeIndex(tree: target.tree, in: root)
    }

    // MARK: - Status

    struct Status {
        var added: [String] = []
        var modified: [String] = []
        var deleted: [String] = []
        var isClean: Bool { added.isEmpty && modified.isEmpty && deleted.isEmpty }
    }

    /// (size, mtime) → sha, keyed by absolute file path — the trust git's own index places in
    /// the same pair. "Trees here are small" was this file's original excuse for having no
    /// cache, and it expired the first time a workspace carried node_modules or an installed
    /// runtime: `status` re-read and re-hashed EVERY byte of every file per call, and the graph
    /// container calls it just by MOUNTING — including as the lane's off-screen edge preview
    /// after an ordinary swipe. On a real phone that read as the shell itself spiking CPU and
    /// memory. Never evicts, like the other registries; a stale entry for a deleted file is
    /// dead weight, not a wrong answer, because only paths the walk actually visits consult it.
    private static let hashCacheLock = NSLock()
    nonisolated(unsafe) private static var hashCache: [String: (size: Int, mtime: Double, sha: String)] = [:]

    /// Worktree vs HEAD, by hashing files — through [hashCache], so only files whose (size,
    /// mtime) moved since the last call are actually read.
    static func status(in root: URL) throws -> Status {
        let headFiles: [String: String]
        if let head = try? headCommit(in: root) {
            headFiles = try flattenTree(head.tree, in: root)
        } else {
            headFiles = [:]
        }
        var worktree: [String: String] = [:]
        collectWorktreeHashes(directory: root, prefix: "", root: root, into: &worktree)

        var result = Status()
        for (path, sha) in worktree {
            switch headFiles[path] {
            case nil: result.added.append(path)
            case sha: break
            default: result.modified.append(path)
            }
        }
        for path in headFiles.keys where worktree[path] == nil {
            result.deleted.append(path)
        }
        result.added.sort(); result.modified.sort(); result.deleted.sort()
        return result
    }

    private static func collectWorktreeHashes(directory: URL, prefix: String, root: URL, into result: inout [String: String]) {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        let children = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? []
        for child in children {
            let name = child.lastPathComponent
            if name == ".git" { continue }
            let path = prefix.isEmpty ? name : "\(prefix)/\(name)"
            let values = try? child.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true {
                collectWorktreeHashes(directory: child, prefix: path, root: root, into: &result)
                continue
            }
            let size = values?.fileSize ?? -1
            let mtime = values?.contentModificationDate?.timeIntervalSinceReferenceDate ?? -1
            let cacheable = size >= 0 && mtime >= 0
            if cacheable {
                hashCacheLock.lock()
                let hit = hashCache[child.path]
                hashCacheLock.unlock()
                if let hit, hit.size == size, hit.mtime == mtime {
                    result[path] = hit.sha
                    continue
                }
            }
            // autoreleasepool per file: `Data(contentsOf:)` parks its buffer in the pool, and a
            // recursion over thousands of files otherwise holds every file's bytes at once —
            // which is a memory footprint the size of the worktree, released only when the walk
            // ends. That, not the hashing, was the RAM half of the spike.
            let sha: String? = autoreleasepool {
                guard let data = try? Data(contentsOf: child) else { return nil }
                return hashObject(.blob, data)
            }
            guard let sha else { continue }
            result[path] = sha
            if cacheable {
                hashCacheLock.lock()
                hashCache[child.path] = (size, mtime, sha)
                hashCacheLock.unlock()
            }
        }
    }

    /// A blob's text at HEAD for a path (for `git diff`), or nil when it isn't there.
    static func headText(of path: String, in root: URL) -> String? {
        guard let head = try? headCommit(in: root),
              let files = try? flattenTree(head.tree, in: root),
              let sha = files[path],
              let (_, content) = try? readObject(sha, in: root) else { return nil }
        return String(data: content, encoding: .utf8)
    }

    // MARK: - Index (DIRC v2)

    /// Write .git/index matching a tree, so the REAL git CLI sees a clean worktree (without
    /// it, desktop git reports every file as deleted+untracked). Stats come from disk; git
    /// re-verifies content when they look racy, so approximate is fine.
    static func writeIndex(tree treeSha: String, in root: URL) throws {
        let files = try flattenTree(treeSha, in: root).sorted { $0.key.utf8.lexicographicallyPrecedes($1.key.utf8) }
        var body = Data("DIRC".utf8)
        appendBE(&body, UInt32(2))
        appendBE(&body, UInt32(files.count))
        let fm = FileManager.default
        for (path, sha) in files {
            let url = root.appendingPathComponent(path)
            let attributes = (try? fm.attributesOfItem(atPath: url.path)) ?? [:]
            let mtime = UInt32((attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
            let size = UInt32(truncatingIfNeeded: (attributes[.size] as? Int) ?? 0)
            appendBE(&body, mtime); appendBE(&body, UInt32(0))   // ctime (mtime is close enough)
            appendBE(&body, mtime); appendBE(&body, UInt32(0))   // mtime
            appendBE(&body, UInt32(0))                            // dev
            appendBE(&body, UInt32(0))                            // ino
            appendBE(&body, UInt32(0o100644))                     // mode
            appendBE(&body, UInt32(0)); appendBE(&body, UInt32(0)) // uid, gid
            appendBE(&body, size)
            body.append(shaToRaw(sha))
            let nameBytes = Array(path.utf8)
            appendBE16(&body, UInt16(min(nameBytes.count, 0xFFF)))
            body.append(contentsOf: nameBytes)
            // Entries pad with NULs to a multiple of 8 (measured from the entry start: 62
            // fixed bytes + name).
            let entryLength = 62 + nameBytes.count
            let padding = 8 - (entryLength % 8)
            body.append(contentsOf: [UInt8](repeating: 0, count: padding == 0 ? 8 : padding))
        }
        let checksum = Insecure.SHA1.hash(data: body)
        body.append(contentsOf: checksum)
        try body.write(to: gitDirectory(root).appendingPathComponent("index"))
    }

    private static func appendBE(_ data: inout Data, _ value: UInt32) {
        var big = value.bigEndian
        data.append(Data(bytes: &big, count: 4))
    }

    private static func appendBE16(_ data: inout Data, _ value: UInt16) {
        var big = value.bigEndian
        data.append(Data(bytes: &big, count: 2))
    }

    // MARK: - zlib (header + raw deflate + adler32, over the Compression framework)

    static func zlibCompress(_ data: Data) throws -> Data {
        var output = Data([0x78, 0x9C])
        let deflated = try transform(data, operation: COMPRESSION_STREAM_ENCODE)
        output.append(deflated)
        var adler = adler32(data).bigEndian
        output.append(Data(bytes: &adler, count: 4))
        return output
    }

    static func zlibDecompress(_ data: Data) throws -> Data {
        guard data.count > 6 else { throw GitError("zlib data too short") }
        // 2-byte header, 4-byte trailing adler32; the middle is raw deflate.
        let raw = data.subdata(in: 2..<(data.count - 4))
        return try transform(raw, operation: COMPRESSION_STREAM_DECODE)
    }

    private static func transform(_ input: Data, operation: compression_stream_operation) throws -> Data {
        var output = Data()
        let bufferSize = 64 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        var stream = compression_stream(dst_ptr: buffer, dst_size: bufferSize, src_ptr: buffer, src_size: 0, state: nil)
        guard compression_stream_init(&stream, operation, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw GitError("zlib init failed")
        }
        defer { compression_stream_destroy(&stream) }

        try input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            stream.src_ptr = raw.bindMemory(to: UInt8.self).baseAddress!
            stream.src_size = input.count
            repeat {
                stream.dst_ptr = buffer
                stream.dst_size = bufferSize
                let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                guard status != COMPRESSION_STATUS_ERROR else { throw GitError("zlib stream error") }
                output.append(buffer, count: bufferSize - stream.dst_size)
                if status == COMPRESSION_STATUS_END { break }
            } while true
        }
        return output
    }

    private static func adler32(_ data: Data) -> UInt32 {
        var a: UInt32 = 1
        var b: UInt32 = 0
        for byte in data {
            a = (a + UInt32(byte)) % 65521
            b = (b + a) % 65521
        }
        return (b << 16) | a
    }

    static func shaToRaw(_ sha: String) -> Data {
        var data = Data(capacity: 20)
        var index = sha.startIndex
        while index < sha.endIndex {
            let next = sha.index(index, offsetBy: 2)
            data.append(UInt8(sha[index..<next], radix: 16) ?? 0)
            index = next
        }
        return data
    }

    static func rawToSha(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Remote config, refs, HEAD (used by the remote engine, GitRemote)

    /// Read/write the "origin" remote URL in .git/config (append-only; one origin).
    static func remoteURL(in root: URL) -> String? {
        guard let config = try? String(contentsOf: gitDirectory(root).appendingPathComponent("config"), encoding: .utf8) else { return nil }
        var inOrigin = false
        for raw in config.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[remote ") { inOrigin = line.contains("\"origin\"") }
            else if line.hasPrefix("[") { inOrigin = false }
            else if inOrigin, line.hasPrefix("url = ") { return String(line.dropFirst("url = ".count)) }
        }
        return nil
    }

    static func setRemote(_ url: String, in root: URL) throws {
        let configURL = gitDirectory(root).appendingPathComponent("config")
        var config = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
        if remoteURL(in: root) == nil {
            config += "[remote \"origin\"]\n\turl = \(url)\n\tfetch = +refs/heads/*:refs/remotes/origin/*\n"
            try config.write(to: configURL, atomically: true, encoding: .utf8)
        }
    }

    /// Point a branch ref at a sha (creating or moving it).
    static func setRef(_ branch: String, to sha: String, in root: URL) throws {
        let ref = gitDirectory(root).appendingPathComponent("refs/heads/\(branch)")
        try FileManager.default.createDirectory(at: ref.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (sha + "\n").write(to: ref, atomically: true, encoding: .utf8)
    }

    static func setHead(branch: String, in root: URL) throws {
        try "ref: refs/heads/\(branch)\n".write(to: gitDirectory(root).appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
    }

    static func refSha(_ branch: String, in root: URL) -> String? {
        try? String(contentsOf: gitDirectory(root).appendingPathComponent("refs/heads/\(branch)"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Record the remote-tracking tip after a push/fetch (refs/remotes/origin/<branch>), so
    /// "ahead of origin?" can be answered without the network.
    static func rememberRemote(branch: String, sha: String, in root: URL) {
        let ref = gitDirectory(root).appendingPathComponent("refs/remotes/origin/\(branch)")
        try? FileManager.default.createDirectory(at: ref.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? (sha + "\n").write(to: ref, atomically: true, encoding: .utf8)
    }

    /// The last-known remote tip for a branch, or nil if never pushed/fetched.
    static func remoteTrackingSha(branch: String, in root: URL) -> String? {
        try? String(contentsOf: gitDirectory(root).appendingPathComponent("refs/remotes/origin/\(branch)"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Object closure (for pushing)

    /// Every object reachable from `commitSha` (the commit, its tree, all subtrees and blobs),
    /// each as (type, content, sha) — the payload of a push. Deduplicated.
    static func reachableObjects(from commitSha: String, in root: URL, excluding known: Set<String> = []) throws -> [(type: ObjectType, content: Data, sha: String)] {
        var collected: [String: (ObjectType, Data)] = [:]
        var visitedTrees: Set<String> = []

        func visitTree(_ treeSha: String) throws {
            guard !visitedTrees.contains(treeSha), !known.contains(treeSha) else { return }
            visitedTrees.insert(treeSha)
            let (type, content) = try readObject(treeSha, in: root)
            guard type == .tree else { return }
            collected[treeSha] = (.tree, content)
            for entry in parseTree(content) {
                if entry.isTree { try visitTree(entry.sha) }
                else if collected[entry.sha] == nil, !known.contains(entry.sha) {
                    let (_, blob) = try readObject(entry.sha, in: root)
                    collected[entry.sha] = (.blob, blob)
                }
            }
        }

        for commit in try log(from: commitSha, in: root, limit: 10_000) where !known.contains(commit.sha) {
            let (_, content) = try readObject(commit.sha, in: root)
            collected[commit.sha] = (.commit, content)
            try visitTree(commit.tree)
        }
        return collected.map { ($0.value.0, $0.value.1, $0.key) }
    }

    /// Materialize a branch's tree into the worktree and point HEAD at it (for clone/fetch
    /// fast-forward). Reuses the checkout machinery once the ref exists.
    static func checkoutDetachedToRef(_ branch: String, in root: URL) throws {
        try checkout(branch, in: root)
    }

    // MARK: - Merge (fast-forward + three-way, diff3 conflict markers)

    enum MergeResult {
        case upToDate
        case fastForward(sha: String)
        case merged(sha: String)
        /// Conflicting files are written to the worktree with markers; resolve them and commit.
        case conflicts([String])
    }

    /// The most recent common ancestor of two commits (breadth-first from `a`, first of `b`'s
    /// ancestors seen). Good enough for the linear-and-simple histories a phone produces.
    static func mergeBase(_ a: String, _ b: String, in root: URL) throws -> String? {
        var ancestorsOfA: Set<String> = []
        var queue = [a]
        while let next = queue.first {
            queue.removeFirst()
            guard ancestorsOfA.insert(next).inserted else { continue }
            if let commit = try? readCommit(next, in: root) { queue.append(contentsOf: commit.parents) }
        }
        var seen: Set<String> = []
        queue = [b]
        while let next = queue.first {
            queue.removeFirst()
            if ancestorsOfA.contains(next) { return next }
            guard seen.insert(next).inserted else { continue }
            if let commit = try? readCommit(next, in: root) { queue.append(contentsOf: commit.parents) }
        }
        return nil
    }

    /// Merge `otherBranch` into the current branch (resolves its tip, then merges by commit).
    static func merge(_ otherBranch: String, in root: URL,
                      author: String = "mouse <mouse@local>") throws -> MergeResult {
        guard let theirSha = branches(in: root)[otherBranch] else {
            throw GitError("no such branch: \(otherBranch)")
        }
        return try merge(commit: theirSha, label: "branch '\(otherBranch)'", in: root, author: author)
    }

    /// Merge an arbitrary commit into the current branch — branch merges and sync's pull half
    /// (merging origin/<branch>'s fetched tip) share this path. Fast-forwards when possible;
    /// otherwise a three-way merge per file. Non-overlapping edits merge cleanly and commit;
    /// overlapping edits are written with `<<<<<<< ======= >>>>>>>` markers and left for the
    /// user (no commit). `label` names the other side in the merge commit message.
    static func merge(commit theirSha: String, label: String, in root: URL,
                      author: String = "mouse <mouse@local>") throws -> MergeResult {
        guard let branch = currentBranch(in: root), let ourSha = refSha(branch, in: root) else {
            throw GitError("no commits on the current branch")
        }
        if ourSha == theirSha { return .upToDate }
        let base = try mergeBase(ourSha, theirSha, in: root)
        if base == theirSha { return .upToDate }              // we already contain them
        if base == ourSha {                                    // pure fast-forward
            try setRef(branch, to: theirSha, in: root)
            try checkout(branch, in: root)
            return .fastForward(sha: theirSha)
        }

        let baseFiles = base.flatMap { try? flattenTree(readCommit($0, in: root).tree, in: root) } ?? [:]
        let ourFiles = try flattenTree(readCommit(ourSha, in: root).tree, in: root)
        let theirFiles = try flattenTree(readCommit(theirSha, in: root).tree, in: root)

        var conflicts: [String] = []
        let paths = Set(baseFiles.keys).union(ourFiles.keys).union(theirFiles.keys)
        for path in paths {
            let outcome = try mergeFile(path: path,
                                        base: baseFiles[path], ours: ourFiles[path], theirs: theirFiles[path],
                                        in: root)
            let url = root.appendingPathComponent(path)
            switch outcome {
            case .delete:
                try? FileManager.default.removeItem(at: url)
            case .content(let data):
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url)
            case .conflict(let data):
                conflicts.append(path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url)
            }
        }

        if !conflicts.isEmpty { return .conflicts(conflicts.sorted()) }

        // Clean merge: commit the worktree with two parents.
        let treeSha = try writeTree(for: root, root: root)
        let timestamp = Int(Date().timeIntervalSince1970)
        var body = "tree \(treeSha)\n"
        body += "parent \(ourSha)\nparent \(theirSha)\n"
        body += "author \(author) \(timestamp) +0000\ncommitter \(author) \(timestamp) +0000\n"
        body += "\nMerge \(label)\n"
        let sha = try writeObject(.commit, Data(body.utf8), in: root)
        try updateHead(to: sha, in: root)
        try? writeIndex(tree: treeSha, in: root)
        return .merged(sha: sha)
    }

    private enum FileMerge { case delete, content(Data), conflict(Data) }

    /// Three-way merge of one path by blob sha. Whole-file decisions first (added/removed on one
    /// side, identical changes); genuinely divergent text falls to the line-level diff3.
    private static func mergeFile(path: String, base: String?, ours: String?, theirs: String?, in root: URL) throws -> FileMerge {
        if ours == theirs { return ours == nil ? .delete : .content(try blob(ours!, in: root)) }
        if ours == base { return theirs == nil ? .delete : .content(try blob(theirs!, in: root)) }
        if theirs == base { return ours == nil ? .delete : .content(try blob(ours!, in: root)) }
        // Both sides diverged from base. Need all three as text to line-merge; else it's a
        // hard conflict (add/add, or edit/delete).
        guard let base, let ours, let theirs,
              let baseText = String(data: try blob(base, in: root), encoding: .utf8),
              let ourText = String(data: try blob(ours, in: root), encoding: .utf8),
              let theirText = String(data: try blob(theirs, in: root), encoding: .utf8) else {
            let ourData = ours.flatMap { try? blob($0, in: root) } ?? Data()
            return .conflict(ourData)   // best-effort body; the path is reported as conflicted
        }
        let (merged, conflict) = diff3(base: lines(baseText), ours: lines(ourText), theirs: lines(theirText))
        // Re-terminate each line. `lines()` split on "\n" and dropped the trailing empty, so
        // rejoin with a newline after every line — but honor a source file that had no final
        // newline (git warns on those; we shouldn't invent one).
        let finalNewline = ourText.hasSuffix("\n") || theirText.hasSuffix("\n")
        var text = merged.map { $0 + "\n" }.joined()
        if !finalNewline, text.hasSuffix("\n") { text.removeLast() }
        return conflict ? .conflict(Data(text.utf8)) : .content(Data(text.utf8))
    }

    private static func blob(_ sha: String, in root: URL) throws -> Data {
        try readObject(sha, in: root).content
    }
    private static func lines(_ text: String) -> [String] {
        var l = text.components(separatedBy: "\n")
        if l.last == "" { l.removeLast() }
        return l
    }

    /// diff3 line merge. Anchors = lines present in all three (matched base↔ours and base↔theirs);
    /// between anchors, each side's chunk is compared against the BASE chunk — if only one side
    /// changed it, take that side; if both changed it differently, emit conflict markers.
    static func diff3(base: [String], ours: [String], theirs: [String]) -> (merged: [String], conflict: Bool) {
        let inOurs = lcsMatch(base, ours)     // base index -> ours index (or nil)
        let inTheirs = lcsMatch(base, theirs) // base index -> theirs index (or nil)

        var merged: [String] = []
        var conflict = false
        var bStart = 0, oi = 0, ti = 0
        var bi = 0
        while bi <= base.count {
            let isAnchor = bi < base.count && inOurs[bi] != nil && inTheirs[bi] != nil
            if isAnchor || bi == base.count {
                let oEnd = isAnchor ? inOurs[bi]! : ours.count
                let tEnd = isAnchor ? inTheirs[bi]! : theirs.count
                emitChunk(base: Array(base[bStart..<bi]),
                          ours: Array(ours[oi..<oEnd]),
                          theirs: Array(theirs[ti..<tEnd]),
                          into: &merged, conflict: &conflict)
                if isAnchor {
                    merged.append(base[bi])
                    oi = oEnd + 1; ti = tEnd + 1; bStart = bi + 1
                }
            }
            bi += 1
        }
        return (merged, conflict)
    }

    private static func emitChunk(base: [String], ours: [String], theirs: [String],
                                  into merged: inout [String], conflict: inout Bool) {
        if ours == theirs { merged.append(contentsOf: ours); return }
        if ours == base { merged.append(contentsOf: theirs); return }   // only theirs changed
        if theirs == base { merged.append(contentsOf: ours); return }   // only ours changed
        // Both sides changed this region differently: conflict.
        conflict = true
        merged.append("<<<<<<< ours")
        merged.append(contentsOf: ours)
        merged.append("=======")
        merged.append(contentsOf: theirs)
        merged.append(">>>>>>> theirs")
    }

    /// For each index in `a`, the index in `b` it maps to on the longest common subsequence
    /// (or nil). The shared backbone the diff3 anchors on.
    private static func lcsMatch(_ a: [String], _ b: [String]) -> [Int?] {
        let n = a.count, m = b.count
        var table = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var result = [Int?](repeating: nil, count: n)
        var i = 0, j = 0
        while i < n && j < m {
            if a[i] == b[j] { result[i] = j; i += 1; j += 1 }
            else if table[i + 1][j] >= table[i][j + 1] { i += 1 }
            else { j += 1 }
        }
        return result
    }

    // MARK: - Streaming inflate (one zlib member out of a concatenated buffer)

    /// Inflate a single zlib member at the start of `input`, returning the output and how many
    /// input bytes it consumed (through the adler32 trailer). Uses libz — the Compression
    /// framework can't delimit concatenated members (it reads past the boundary), which the
    /// packfile reader relies on to walk object-after-object.
    static func inflateStream(_ input: Data) throws -> (output: Data, consumed: Int) {
        var stream = z_stream()
        guard inflateInit_(&stream, zlibVersion(), Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw GitError("zlib init failed")
        }
        defer { inflateEnd(&stream) }

        var output = Data()
        let chunkSize = 64 * 1024
        var chunk = [UInt8](repeating: 0, count: chunkSize)

        let consumed: Int = try input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let inputBase = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            stream.next_in = UnsafeMutablePointer(mutating: inputBase)
            stream.avail_in = uInt(input.count)
            while true {
                let status: Int32 = chunk.withUnsafeMutableBufferPointer { out in
                    stream.next_out = out.baseAddress
                    stream.avail_out = uInt(chunkSize)
                    let result = inflate(&stream, Z_NO_FLUSH)
                    let produced = chunkSize - Int(stream.avail_out)
                    if produced > 0 { output.append(out.baseAddress!, count: produced) }
                    return result
                }
                if status == Z_STREAM_END { break }
                guard status == Z_OK || status == Z_BUF_ERROR else { throw GitError("zlib inflate error \(status)") }
                if stream.avail_in == 0 && status == Z_BUF_ERROR { break }
            }
            return input.count - Int(stream.avail_in)
        }
        return (output, consumed)
    }

    // MARK: - Packfiles (the wire format for clone/fetch/push)

    private static func packTypeNumber(_ type: ObjectType) -> Int {
        switch type { case .commit: 1; case .tree: 2; case .blob: 3 }
    }
    private static func packType(_ number: Int) -> ObjectType? {
        switch number { case 1: .commit; case 2: .tree; case 3: .blob; default: nil }
    }

    /// A pack object's variable-length type+size header (git packfile format).
    private static func packObjectHeader(type: Int, size: Int) -> Data {
        var bytes: [UInt8] = []
        var value = size
        var byte = UInt8((type << 4) | (value & 0x0f))
        value >>= 4
        while value > 0 {
            bytes.append(byte | 0x80)
            byte = UInt8(value & 0x7f)
            value >>= 7
        }
        bytes.append(byte)
        return Data(bytes)
    }

    /// Serialize objects into a v2 packfile (header, per-object zlib bodies, SHA-1 trailer) —
    /// exactly what `git index-pack` accepts. Objects are stored whole (no delta compression;
    /// GitHub re-packs server-side).
    static func writePackfile(_ objects: [(type: ObjectType, content: Data, sha: String)]) throws -> Data {
        var pack = Data("PACK".utf8)
        var version = UInt32(2).bigEndian
        pack.append(Data(bytes: &version, count: 4))
        var count = UInt32(objects.count).bigEndian
        pack.append(Data(bytes: &count, count: 4))
        for object in objects {
            pack.append(packObjectHeader(type: packTypeNumber(object.type), size: object.content.count))
            pack.append(try zlibCompress(object.content))
        }
        pack.append(contentsOf: Insecure.SHA1.hash(data: pack))
        return pack
    }

    /// Read a v2 packfile, writing every object (delta-resolved) into the loose store. Handles
    /// OFS_DELTA and REF_DELTA, which real GitHub always sends. Returns the object count.
    @discardableResult
    static func readPackfile(_ data: Data, into root: URL) throws -> Int {
        let bytes = [UInt8](data)
        guard bytes.count > 12, Array(bytes[0..<4]) == Array("PACK".utf8) else { throw GitError("not a packfile") }
        let count = (UInt32(bytes[8]) << 24) | (UInt32(bytes[9]) << 16) | (UInt32(bytes[10]) << 8) | UInt32(bytes[11])
        var offset = 12
        // Resolved objects by their byte offset in the pack (OFS_DELTA bases point here).
        var byOffset: [Int: (type: ObjectType, content: Data)] = [:]

        for _ in 0..<count {
            let objectOffset = offset
            var c = Int(bytes[offset]); offset += 1
            let type = (c >> 4) & 7
            var size = c & 0x0f
            var shift = 4
            while c & 0x80 != 0 {
                c = Int(bytes[offset]); offset += 1
                size |= (c & 0x7f) << shift
                shift += 7
            }
            _ = size   // uncompressed size, informational

            func inflateHere() throws -> Data {
                let (out, consumed) = try inflateStream(data.subdata(in: offset..<data.count))
                offset += consumed
                return out
            }

            switch type {
            case 1, 2, 3:
                let content = try inflateHere()
                let objectType = packType(type)!
                byOffset[objectOffset] = (objectType, content)
                try writeObject(objectType, content, in: root)
            case 6:   // OFS_DELTA: base is `baseRelative` bytes earlier in the pack
                var b = Int(bytes[offset]); offset += 1
                var baseRelative = b & 0x7f
                while b & 0x80 != 0 {
                    b = Int(bytes[offset]); offset += 1
                    baseRelative = ((baseRelative + 1) << 7) | (b & 0x7f)
                }
                let delta = try inflateHere()
                guard let base = byOffset[objectOffset - baseRelative] else { throw GitError("ofs-delta base missing") }
                let result = applyDelta(base: base.content, delta: delta)
                byOffset[objectOffset] = (base.type, result)
                try writeObject(base.type, result, in: root)
            case 7:   // REF_DELTA: base named by 20-byte sha (already in the store)
                let baseSha = bytes[offset..<offset + 20].map { String(format: "%02x", $0) }.joined()
                offset += 20
                let delta = try inflateHere()
                let (baseType, baseContent) = try readObject(baseSha, in: root)
                let result = applyDelta(base: baseContent, delta: delta)
                byOffset[objectOffset] = (baseType, result)
                try writeObject(baseType, result, in: root)
            default:
                throw GitError("unknown pack object type \(type)")
            }
        }
        return Int(count)
    }

    /// Apply a git delta (copy-from-base / insert-literal opcodes) to a base object.
    static func applyDelta(base: Data, delta: Data) -> Data {
        let baseBytes = [UInt8](base)
        let d = [UInt8](delta)
        var i = 0
        func varint() -> Int {
            var result = 0, shift = 0
            while i < d.count {
                let c = Int(d[i]); i += 1
                result |= (c & 0x7f) << shift
                shift += 7
                if c & 0x80 == 0 { break }
            }
            return result
        }
        _ = varint()   // base size
        _ = varint()   // target size
        var out = [UInt8]()
        while i < d.count {
            let opcode = d[i]; i += 1
            if opcode & 0x80 != 0 {
                var copyOffset = 0, copySize = 0
                if opcode & 0x01 != 0 { copyOffset |= Int(d[i]); i += 1 }
                if opcode & 0x02 != 0 { copyOffset |= Int(d[i]) << 8; i += 1 }
                if opcode & 0x04 != 0 { copyOffset |= Int(d[i]) << 16; i += 1 }
                if opcode & 0x08 != 0 { copyOffset |= Int(d[i]) << 24; i += 1 }
                if opcode & 0x10 != 0 { copySize |= Int(d[i]); i += 1 }
                if opcode & 0x20 != 0 { copySize |= Int(d[i]) << 8; i += 1 }
                if opcode & 0x40 != 0 { copySize |= Int(d[i]) << 16; i += 1 }
                if copySize == 0 { copySize = 0x10000 }
                if copyOffset + copySize <= baseBytes.count {
                    out.append(contentsOf: baseBytes[copyOffset..<copyOffset + copySize])
                }
            } else if opcode != 0 {
                let n = Int(opcode)
                out.append(contentsOf: d[i..<i + n])
                i += n
            }
        }
        return Data(out)
    }

    // MARK: - pkt-line (the smart-HTTP framing)

    /// A single pkt-line: 4 hex length digits (including the 4) + payload. Empty payload → flush.
    static func pktLine(_ payload: Data) -> Data {
        guard !payload.isEmpty else { return Data("0000".utf8) }
        let length = payload.count + 4
        var line = Data(String(format: "%04x", length).utf8)
        line.append(payload)
        return line
    }
    static func pktLine(_ text: String) -> Data { pktLine(Data(text.utf8)) }
    static var pktFlush: Data { Data("0000".utf8) }

    /// Split a pkt-line stream into its payloads (flush packets become empty Data markers).
    static func parsePktLines(_ data: Data) -> [Data] {
        let bytes = [UInt8](data)
        var lines: [Data] = []
        var i = 0
        while i + 4 <= bytes.count {
            let hex = String(bytes: bytes[i..<i + 4], encoding: .utf8) ?? ""
            guard let length = Int(hex, radix: 16) else { break }
            if length == 0 { lines.append(Data()); i += 4; continue }   // flush
            guard length >= 4, i + length <= bytes.count else { break }
            lines.append(Data(bytes[i + 4..<i + length]))
            i += length
        }
        return lines
    }
}
