import Foundation

/// `GitCore.status` — the worktree diff, through the (size, mtime) hash cache.
///
/// The cache exists because "trees here are small" expired: a workspace with node_modules or an
/// installed runtime made every `status` call re-read and re-hash the whole tree, and the graph
/// container calls `status` just by mounting — including as a lane's off-screen edge preview, so
/// an ordinary swipe read as a CPU and memory spike on a real phone. A cache that answers wrong
/// would be worse than the spike: `status` decides the commit button and what a commit contains.
/// So every check here runs AFTER the cache is warm, and each one is a way the cache could lie:
/// a changed file it should re-read, a deleted file it should not resurrect, an added file it has
/// never seen, a same-size edit, an mtime pushed BACKWARD.
///
/// The racy window git's own index has, this cache has too: an edit that lands within the mtime
/// resolution AND keeps the byte count is invisible until either moves. APFS mtimes are
/// nanosecond, so the window is not reachable by anything slower than a syscall loop; recorded
/// here rather than gated, because a test that needs a nanosecond collision to fail is noise.
var failures = 0
func check(_ condition: Bool, _ label: String) {
    if !condition {
        failures += 1
        print("  FAIL: \(label)")
    }
}

let base = FileManager.default.temporaryDirectory
    .appendingPathComponent("gitstatus-\(ProcessInfo.processInfo.processIdentifier)")
try? FileManager.default.removeItem(at: base)
try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: base) }

func write(_ path: String, _ text: String) throws {
    let url = base.appendingPathComponent(path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
}

// A tree with some depth, so the recursive walk and the cache both see nested paths.
try GitCore.initRepo(base)
try write("readme.md", "hello\n")
try write("src/main.js", "console.log(1)\n")
try write("src/lib/util.js", "module.exports = 7\n")

// Nothing committed yet: everything is "added".
let before = try GitCore.status(in: base)
check(before.added.sorted() == ["readme.md", "src/lib/util.js", "src/main.js"],
      "before the first commit every file is added — got \(before.added)")

_ = try GitCore.commitAll(in: base, message: "first")
check(try GitCore.status(in: base).isClean, "clean immediately after a commit")

// The cache is now warm for every file. Each check below is a distinct way it could lie.

// 1. A changed file (new size, new mtime) must be re-read.
try write("src/main.js", "console.log(2) // changed\n")
check(try GitCore.status(in: base).modified == ["src/main.js"],
      "an edited file shows as modified through the warm cache")

// 2. A SAME-SIZE edit: only mtime moves. The cheapest lie is "size matched, skip it".
try write("readme.md", "HELLO\n")
check(try GitCore.status(in: base).modified.contains("readme.md"),
      "a same-size edit is still seen (mtime alone must invalidate)")

// 3. An mtime pushed BACKWARD (a tar extract preserving old dates does this).
try write("src/lib/util.js", "module.exports = 8\n")
let old = Date(timeIntervalSince1970: 1_000_000)
try FileManager.default.setAttributes([.modificationDate: old],
                                      ofItemAtPath: base.appendingPathComponent("src/lib/util.js").path)
check(try GitCore.status(in: base).modified.contains("src/lib/util.js"),
      "a backdated mtime still differs from the cached one — inequality, not ordering")

// 4. Added and deleted files around the warm cache.
try write("src/new.js", "fresh\n")
try FileManager.default.removeItem(at: base.appendingPathComponent("readme.md"))
let moved = try GitCore.status(in: base)
check(moved.added == ["src/new.js"], "a new file is added — got \(moved.added)")
check(moved.deleted == ["readme.md"],
      "a deleted file is deleted, not resurrected from its cache entry — got \(moved.deleted)")

// 5. Committing the lot lands clean again — the shas the cache supplied were the true ones,
//    or this commit would disagree with the worktree it just wrote.
_ = try GitCore.commitAll(in: base, message: "second")
check(try GitCore.status(in: base).isClean, "clean after committing through cached hashes")

// 6. Two consecutive calls agree byte for byte (the second is all cache hits).
let a = try GitCore.status(in: base)
try write("src/main.js", "console.log(3)\n")
let b = try GitCore.status(in: base)
let c = try GitCore.status(in: base)
check(a.isClean, "call one: clean")
check(b.modified == c.modified && b.added == c.added && b.deleted == c.deleted,
      "a cache-hit run answers exactly what the run that filled it answered")

if failures == 0 {
    print("GIT STATUS: 10 checks — the worktree diff through the (size, mtime) cache: edits, same-size edits, backdated mtimes, add/delete, commit round-trip — MATCH")
} else {
    print("GIT STATUS: \(failures) of 10 checks failed — MISMATCH")
    exit(1)
}
