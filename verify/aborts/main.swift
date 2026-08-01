import Foundation
setvbuf(stdout, nil, _IONBF, 0)

// The same corpus through real node and through this engine, line for line. What a signal
// REPORTS matters as much as whether it fired: a caller branches on `reason`, so a cancellation
// carrying the wrong one is worse than a cancellation that never arrives.
let realNode = "/Users/thyfriendlyfox/.local/bin/node"
let here = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let corpus = here.appendingPathComponent("corpus.js")
let source = (try? String(contentsOf: corpus, encoding: .utf8)) ?? ""

let node = Process()
node.executableURL = URL(fileURLWithPath: realNode)
node.arguments = [corpus.path]
let out = Pipe(), err = Pipe()
node.standardOutput = out
node.standardError = err
try? node.run()
let theirText = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
let theirErr = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
node.waitUntilExit()

let engine = NodeEngine(root: here, env: ["PATH": "/usr/bin"])
let started = Date()
let mine = await engine.run(source: source, path: "/corpus.js",
                            argv: ["node", "/corpus.js"], cwd: "/", stdin: "")
// The corpus creates an `AbortSignal.timeout(100000)` and never cancels it. A signal's deadline
// must not be a reason for the process to stay alive, so the run has to END rather than wait it
// out — which is only observable as elapsed time, not as a line of output.
let elapsed = Date().timeIntervalSince(started)

func rows(_ text: String) -> [(name: String, value: String)] {
    text.split(separator: "\n").compactMap { line in
        let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        return parts.count == 2 ? (parts[0], parts[1]) : nil
    }
}

let theirRows = rows(theirText), ourRows = rows(mine.out)
var ours: [String: String] = [:]
for row in ourRows { ours[row.name] = row.value }

var differences: [String] = []
for row in theirRows {
    let got = ours[row.name] ?? "<scenario missing entirely>"
    if got != row.value {
        differences.append("  \(row.name)\n    node: \(row.value)\n    ours: \(got)")
    }
}

if theirRows.isEmpty {
    print("ABORT MISMATCH — real node produced no rows:\n\(theirText.prefix(400))\n\(theirErr.prefix(400))")
    exit(1)
}
if elapsed > 30 {
    print("ABORT MISMATCH — the run took \(Int(elapsed))s: a pending AbortSignal.timeout held "
          + "the loop open instead of being unref'd")
    exit(1)
}
if differences.isEmpty, theirRows.count == ourRows.count {
    print("ABORT MATCH — all \(theirRows.count) behaviours identical to real node: the reason a "
          + "signal carries and where it comes from, listener order and the event object, a "
          + "listener attached after the abort, the statics (abort, any, timeout), and what "
          + "timers/promises and the events helpers do with a signal — including an already "
          + "aborted one")
} else {
    print("rows — node: \(theirRows.count), ours: \(ourRows.count)")
    for difference in differences { print(difference) }
    for row in ourRows where !theirRows.contains(where: { $0.name == row.name }) {
        print("  \(row.name) — ours only: \(row.value)")
    }
    if !mine.err.isEmpty { print("our stderr: \(mine.err.prefix(500))") }
    print("ABORT MISMATCH — \(max(differences.count, abs(theirRows.count - ourRows.count))) of \(theirRows.count) differ")
    exit(1)
}
