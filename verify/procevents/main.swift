import Foundation
setvbuf(stdout, nil, _IONBF, 0)
// Process lifecycle events, swept after exit/beforeExit turned out never to fire. Only stdout
// is compared — node's stderr carries a pid and a --trace-warnings hint that differ by run —
// but the stderr CONTRACT is asserted separately below.
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
        print("    <- \(source.prefix(64))")
        bad += 1
    }
}
// A warning still reaches stderr even when someone is listening — a listener observes, it does
// not suppress. That is the half a stdout comparison cannot see.
let e2 = NodeEngine(root: here, env: [:])
let watched = await e2.run(source: "process.on('warning', () => {}); process.emitWarning('still printed');",
                           path: "/w.js", argv: ["node"], cwd: "/", stdin: "")
if !watched.err.contains("still printed") { print("  a listener suppressed the stderr warning"); bad += 1 }
let e3 = NodeEngine(root: here, env: [:])
let coded = await e3.run(source: "process.emitWarning('x', { type: 'T', code: 'C1' });",
                         path: "/w.js", argv: ["node"], cwd: "/", stdin: "")
if !coded.err.contains("[C1] T: x") { print("  stderr missing the code/type form: \(coded.err.prefix(60))"); bad += 1 }

if bad == 0 { print("PROCESS EVENTS MATCH — all \(cases.count) cases, and warnings still reach stderr") }
else { print("PROCESS EVENTS DIFFER — \(bad)"); exit(1) }
