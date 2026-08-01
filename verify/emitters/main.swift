import Foundation
setvbuf(stdout, nil, _IONBF, 0)

// The same corpus through real node and through this engine, line for line. Uncaught throws are
// part of the answer here — several scenarios end the process on purpose — so the comparison
// covers stdout, the exit status, and the ERROR each engine reports when an 'error' event has
// nobody listening.
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
let mine = await engine.run(source: source, path: "/corpus.js",
                            argv: ["node", "/corpus.js"], cwd: "/", stdin: "")

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
    print("EMITTER MISMATCH — real node produced no rows:\n\(theirText.prefix(400))\n\(theirErr.prefix(400))")
    exit(1)
}
if differences.isEmpty, theirRows.count == ourRows.count {
    print("EMITTER MATCH — all \(theirRows.count) behaviours identical to real node: listener "
          + "order and duplicates, what `once` leaves behind, mutation during an emit in flight, "
          + "the newListener/removeListener meta events, introspection, an 'error' with nobody "
          + "listening, errorMonitor, and the promise and async-iterator helpers")
} else {
    print("rows — node: \(theirRows.count), ours: \(ourRows.count)")
    for difference in differences { print(difference) }
    for row in ourRows where !theirRows.contains(where: { $0.name == row.name }) {
        print("  \(row.name) — ours only: \(row.value)")
    }
    if !mine.err.isEmpty { print("our stderr: \(mine.err.prefix(500))") }
    print("EMITTER MISMATCH — \(max(differences.count, abs(theirRows.count - ourRows.count))) of \(theirRows.count) differ")
    exit(1)
}
