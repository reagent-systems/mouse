import Foundation
setvbuf(stdout, nil, _IONBF, 0)
let here = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let source = (try? String(contentsOf: here.appendingPathComponent("probe.js"), encoding: .utf8)) ?? ""
let expected = ((try? String(contentsOf: here.appendingPathComponent("node.txt"), encoding: .utf8)) ?? "")
    .trimmingCharacters(in: .whitespacesAndNewlines)
let engine = NodeEngine(root: here, env: [:])
let mine = await engine.run(source: source, path: "/probe.js", argv: ["node", "/probe.js"], cwd: "/", stdin: "")
let ours = mine.out.trimmingCharacters(in: .whitespacesAndNewlines)
// Compared as a whole, INCLUDING the interleaved ordered-1/2/3 lines: a reparented stdout that
// buffered differently would reorder them, which is the regression worth fearing here.
let a = expected.split(separator: "\n").map(String.init), b = ours.split(separator: "\n").map(String.init)
var bad = 0
for i in 0..<max(a.count, b.count) {
    let want = i < a.count ? a[i] : "<missing>", got = i < b.count ? b[i] : "<missing>"
    if want != got { print("  node: \(want)\n  ours: \(got)"); bad += 1 }
}
if bad == 0 && !ours.isEmpty { print("STDIO SHAPE MATCH — all \(a.count) lines, prototypes and ORDER both") }
else { print("STDIO SHAPE MISMATCH — \(bad) of \(a.count)")
       if !mine.err.isEmpty { print("stderr: \(mine.err.prefix(400))") }; exit(1) }
