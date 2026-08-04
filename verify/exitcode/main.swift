import Foundation
setvbuf(stdout, nil, _IONBF, 0)

// `process.exitCode = n` is the other way a program reports failure: it does not exit, it
// records what the status should be once the loop drains. Nothing read it back, so every tool
// that reports failure this way — mocha, and any runner or linter that lets pending work
// finish — exited 0 on failure. A test suite that exits 0 when tests fail is worse than no
// suite at all, so this is gated case by case rather than trusted.
let here = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let cases = ((try? String(contentsOf: here.appendingPathComponent("cases.txt"), encoding: .utf8)) ?? "")
    .split(separator: "\n").map(String.init)
var expected: [String: Int32] = [:]
for line in ((try? String(contentsOf: here.appendingPathComponent("node.txt"), encoding: .utf8)) ?? "")
    .split(separator: "\n").map(String.init) {
    guard let r = line.range(of: " <- ") else { continue }
    expected[String(line[r.upperBound...])] = Int32(line[..<r.lowerBound]) ?? -1
}
var bad = 0
for source in cases {
    let engine = NodeEngine(root: here, env: [:])
    let mine = await engine.run(source: source, path: "/e.js", argv: ["node", "-e", source], cwd: "/", stdin: "")
    let want = expected[source] ?? -1
    if mine.status != want {
        print("  node=\(want) ours=\(mine.status)  <- \(source)")
        if !mine.err.isEmpty { print("    stderr: \(mine.err.prefix(200))") }
        bad += 1
    }
}
if bad == 0 { print("EXIT CODES MATCH — all \(cases.count) cases agree with node") }
else { print("EXIT CODES DIFFER — \(bad) of \(cases.count)"); exit(1) }
