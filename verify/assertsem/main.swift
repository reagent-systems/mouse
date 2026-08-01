import Foundation
setvbuf(stdout, nil, _IONBF, 0)
let here = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let source = (try? String(contentsOf: here.appendingPathComponent("probe.js"), encoding: .utf8)) ?? ""
let expected = ((try? String(contentsOf: here.appendingPathComponent("node.txt"), encoding: .utf8)) ?? "")
    .trimmingCharacters(in: .whitespacesAndNewlines)
let engine = NodeEngine(root: here, env: [:])
let mine = await engine.run(source: source, path: "/probe.js", argv: ["node", "/probe.js"], cwd: "/", stdin: "")
let ours = mine.out.trimmingCharacters(in: .whitespacesAndNewlines)
// Keyed by label, so one divergence cannot shift every later line.
func table(_ text: String) -> [(String, String)] {
    text.split(separator: "\n").map(String.init).compactMap { line in
        if let r = line.range(of: ": ") { return (String(line[..<r.lowerBound]), String(line[r.upperBound...])) }
        if let r = line.range(of: " MSG ") { return (String(line[..<r.lowerBound]), String(line[r.upperBound...])) }
        return nil
    }
}
let oursBy = Dictionary(table(ours), uniquingKeysWith: { a, _ in a })
var bad = 0
let want = table(expected)
for (label, value) in want {
    let got = oursBy[label] ?? "<missing>"
    if got != value { print("  \(label):\n    node: \(value)\n    ours: \(got)"); bad += 1 }
}
if bad == 0 && !ours.isEmpty { print("ASSERT SEMANTICS MATCH — all \(want.count) behaviours and full messages") }
else { print("ASSERT SEMANTICS DIFFER — \(bad) of \(want.count)")
       if !mine.err.isEmpty { print("stderr: \(mine.err.prefix(400))") }; exit(1) }
