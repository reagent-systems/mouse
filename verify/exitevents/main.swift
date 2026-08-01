import Foundation
setvbuf(stdout, nil, _IONBF, 0)

// `exit` and `beforeExit` were never emitted at all. They are where cleanup lives — flushing a
// log, writing coverage, removing a lockfile — so a process that skips them loses work silently
// rather than failing. Found by chasing why ink printed nothing under a non-TTY run.
//
// The ORDER matters as much as the firing: beforeExit runs while the loop can still be revived,
// exit runs last and synchronously, and neither fires after an explicit process.exit() except
// exit itself.
let here = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let cases = ((try? String(contentsOf: here.appendingPathComponent("cases.txt"), encoding: .utf8)) ?? "")
    .split(separator: "\n").map(String.init)
var expected: [String: String] = [:]
for line in ((try? String(contentsOf: here.appendingPathComponent("node.txt"), encoding: .utf8)) ?? "")
    .split(separator: "\n").map(String.init) {
    guard let r = line.range(of: "<- ") else { continue }
    expected[String(line[r.upperBound...])] = String(line[..<r.lowerBound])
}
var bad = 0
for source in cases {
    let engine = NodeEngine(root: here, env: [:])
    let mine = await engine.run(source: source, path: "/e.js", argv: ["node", "-e", source], cwd: "/", stdin: "")
    let got = mine.out.replacingOccurrences(of: "\n", with: "|")
    let want = expected[source] ?? "<no baseline>"
    if got != want {
        print("  node: \(want.isEmpty ? "<nothing>" : want)")
        print("  ours: \(got.isEmpty ? "<nothing>" : got)")
        print("    <- \(source.prefix(70))")
        bad += 1
    }
}
if bad == 0 { print("EXIT EVENTS MATCH — all \(cases.count) cases fire as node's do") }
else { print("EXIT EVENTS DIFFER — \(bad) of \(cases.count)"); exit(1) }
