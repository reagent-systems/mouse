import Foundation
setvbuf(stdout, nil, _IONBF, 0)

// The HISTORY the graph draws, against real git's answer for the same repository. Every gap
// found here was silent: the graph rendered a clean list of commits that simply stopped, and
// nothing on screen said the rest existed.
//
// The fixture is built by real git and deliberately has the four shapes that broke it:
//   1. more than 200 commits            — the old per-tip cap
//   2. a branch name with a slash       — refs/heads/feat/nested is a DIRECTORY
//   3. refs packed away                 — `git pack-refs --all` empties those directories
//   4. objects packed away              — `git gc` leaves nothing loose to read
// Real git is the oracle for all of it: `for-each-ref` for the branches, `rev-list` for the
// commits reachable from them.

let realGit = "/usr/bin/git"
let base = FileManager.default.temporaryDirectory
    .appendingPathComponent("githistory-\(ProcessInfo.processInfo.processIdentifier)")
defer { try? FileManager.default.removeItem(at: base) }

@discardableResult
func git(_ arguments: [String], in directory: URL) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: realGit)
    process.arguments = arguments
    process.currentDirectoryURL = directory
    process.environment = ProcessInfo.processInfo.environment.merging([
        "GIT_AUTHOR_NAME": "Gate", "GIT_AUTHOR_EMAIL": "gate@example.com",
        "GIT_COMMITTER_NAME": "Gate", "GIT_COMMITTER_EMAIL": "gate@example.com",
    ]) { _, new in new }
    let out = Pipe()
    process.standardOutput = out
    process.standardError = Pipe()
    try? process.run()
    let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
}

var failures = 0
func check(_ condition: Bool, _ label: String) {
    if !condition {
        failures += 1
        print("  FAIL: \(label)")
    }
}

try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
git(["init", "-q", "-b", "main"], in: base)
// 220 commits: past the 200 the walk used to stop at, and enough that a cap would show.
for i in 1...220 {
    git(["commit", "-q", "--allow-empty", "-m", "commit \(i)"], in: base)
}
// A namespaced branch, which lives in a DIRECTORY under refs/heads.
git(["checkout", "-q", "-b", "feat/nested"], in: base)
for i in 1...6 {
    git(["commit", "-q", "--allow-empty", "-m", "nested \(i)"], in: base)
}
git(["checkout", "-q", "main"], in: base)
// A merge, so the walk has a commit with two parents to follow.
git(["merge", "-q", "--no-ff", "-m", "merge nested", "feat/nested"], in: base)
// And now the shapes a repository cloned by real git actually has: everything packed.
git(["gc", "-q", "--prune=now"], in: base)
git(["pack-refs", "--all"], in: base)

let looseObjects = (try? FileManager.default.subpathsOfDirectory(
    atPath: base.appendingPathComponent(".git/objects").path))?
    .filter { !$0.hasPrefix("pack") && !$0.hasPrefix("info") && $0.contains("/") }.count ?? 0
// FILES only: `pack-refs` leaves the now-empty `feat/` directory behind, and an empty directory
// is not a ref.
let refsDir = base.appendingPathComponent(".git/refs/heads")
let looseRefs = ((try? FileManager.default.subpathsOfDirectory(atPath: refsDir.path)) ?? [])
    .filter { path in
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: refsDir.appendingPathComponent(path).path,
                                       isDirectory: &isDirectory)
        return !isDirectory.boolValue
    }.count
print("fixture: \(looseObjects) loose objects, \(looseRefs) loose refs — everything is packed")
check(looseObjects == 0, "the fixture really is packed (else the gate proves nothing)")
check(looseRefs == 0, "the fixture's refs really are packed")

// 1. Branches, ours against git's.
let realBranches = Set(git(["for-each-ref", "--format=%(refname:short)", "refs/heads"], in: base)
    .split(separator: "\n").map(String.init))
let ours = GitCore.branches(in: base)
check(Set(ours.keys) == realBranches,
      "branches: ours \(Set(ours.keys).sorted()) vs git \(realBranches.sorted())")
check(realBranches.contains("feat/nested"), "the fixture has the namespaced branch")
for (name, sha) in ours {
    let real = git(["rev-parse", name], in: base)
    check(sha == real, "\(name) points where git says (\(sha.prefix(8)) vs \(real.prefix(8)))")
}

// 2. Every commit reachable from every branch, ours against git's.
var visited: Set<String> = [], have: Set<String> = [], parents: [String: [String]] = [:]
var queue = Array(ours.values), cursor = 0
while cursor < queue.count {
    let sha = queue[cursor]
    cursor += 1
    guard visited.insert(sha).inserted else { continue }
    guard let commit = try? GitCore.readCommit(sha, in: base) else { continue }
    have.insert(sha)
    parents[sha] = commit.parents
    queue.append(contentsOf: commit.parents)
}
let realCount = Int(git(["rev-list", "--count", "--branches"], in: base)) ?? -1
print("history: ours \(have.count) commits, git \(realCount)")
check(have.count == realCount, "every commit git can reach, we can reach")
check(!parents.contains { $0.value.contains { !have.contains($0) } },
      "no parent is left dangling — the walk reports itself complete")
check(have.count > 200, "more than the old 200-commit cap (\(have.count))")

// 3. `log` from a tip walks the whole branch rather than stopping at the default limit, and an
//    unreadable ancestor ends the walk instead of discarding everything already read.
if let tip = ours["main"] {
    let full = (try? GitCore.log(from: tip, in: base, limit: .max)) ?? []
    let mainCount = Int(git(["rev-list", "--count", "main"], in: base)) ?? -1
    check(full.count == mainCount, "log(limit: .max) from main: \(full.count) vs git \(mainCount)")
    let capped = (try? GitCore.log(from: tip, in: base)) ?? []
    check(capped.count == 200, "the default limit still bounds a listing at 200 (\(capped.count))")
}
// A tip that does not exist is still an error — asking for the history of nothing is a mistake,
// not an empty history.
check((try? GitCore.log(from: String(repeating: "0", count: 40), in: base)) == nil,
      "an unreadable STARTING commit throws")

if failures == 0 {
    print("GIT HISTORY: \(have.count) commits over \(ours.count) branches, packed objects and packed refs, matches real git — MATCH")
} else {
    print("GIT HISTORY: \(failures) checks failed — MISMATCH")
    exit(1)
}
