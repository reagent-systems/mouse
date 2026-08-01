import Foundation
setvbuf(stdout, nil, _IONBF, 0)
// axios is the most-used HTTP client in Node and it leans on exactly what this session changed:
// its own Agent, redirects, timeouts, JSON parsing, and HTTP errors surfaced as rejections. A
// library-level proof of the agent work rather than another hand-written request.
let here = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let source = (try? String(contentsOf: here.appendingPathComponent("probe.js"), encoding: .utf8)) ?? ""
let expected = ((try? String(contentsOf: here.appendingPathComponent("node.txt"), encoding: .utf8)) ?? "")
    .trimmingCharacters(in: .whitespacesAndNewlines)
let engine = NodeEngine(root: here, env: ["PATH": "/usr/bin"])
let started = Date()
let mine = await engine.run(source: source, path: "/probe.js", argv: ["node", "/probe.js"], cwd: "/", stdin: "")
let elapsed = Date().timeIntervalSince(started)
let ours = mine.out.trimmingCharacters(in: .whitespacesAndNewlines)
var oursBy: [String: String] = [:]
for line in ours.split(separator: "\n").map(String.init) {
    if let r = line.range(of: ": ") { oursBy[String(line[..<r.lowerBound])] = String(line[r.upperBound...]) }
}
var bad = 0
let want = expected.split(separator: "\n").map(String.init)
for line in want {
    guard let r = line.range(of: ": ") else { print("  node: \(line)"); bad += 1; continue }
    let label = String(line[..<r.lowerBound]), value = String(line[r.upperBound...])
    let got = oursBy[label] ?? "<missing>"
    if got != value { print("  \(label):\n    node: \(value)\n    ours: \(got)"); bad += 1 }
}
if bad == 0 && !ours.isEmpty {
    print("AXIOS MATCH — all \(want.count) behaviours identical to node (\(String(format: "%.1f", elapsed))s)")
} else {
    print("AXIOS DIFFERS — \(bad) of \(want.count)")
    if !mine.err.isEmpty { print("stderr: \(mine.err.prefix(600))") }
    exit(1)
}
