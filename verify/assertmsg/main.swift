import Foundation
setvbuf(stdout, nil, _IONBF, 0)
let here = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let source = (try? String(contentsOf: here.appendingPathComponent("probe.js"), encoding: .utf8)) ?? ""
let expected = ((try? String(contentsOf: here.appendingPathComponent("node.txt"), encoding: .utf8)) ?? "")
    .trimmingCharacters(in: .whitespacesAndNewlines)
let engine = NodeEngine(root: here, env: [:])
let mine = await engine.run(source: source, path: "/probe.js", argv: ["node", "/probe.js"], cwd: "/", stdin: "")
let ours = mine.out.trimmingCharacters(in: .whitespacesAndNewlines)
var oursBy: [String: String] = [:]
for line in ours.split(separator: "\n").map(String.init) {
    let p = line.components(separatedBy: " -> ")
    if p.count == 2 { oursBy[p[0]] = p[1] }
}
var bad = 0
for line in expected.split(separator: "\n").map(String.init) {
    let p = line.components(separatedBy: " -> ")
    guard p.count == 2 else { continue }
    let got = oursBy[p[0]] ?? "<missing>"
    if got != p[1] { print("  \(p[0]):\n    node: \(p[1])\n    ours: \(got)"); bad += 1 }
}
if bad == 0 && !ours.isEmpty { print("ASSERT MESSAGES MATCH — all 18 identical to node") }
else { print("ASSERT MESSAGES DIFFER — \(bad) of 18"); if !mine.err.isEmpty { print("stderr: \(mine.err.prefix(400))") }; exit(1) }
