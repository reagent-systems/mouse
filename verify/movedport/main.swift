import Foundation
setvbuf(stdout, nil, _IONBF, 0)
// A port moved into a vm context. The refusal read "contexts are separate engines with no shared
// memory" — true when a vm context WAS another engine, and expired the moment they became a
// second JSContext in the same virtual machine. Nothing about it was ever impossible.
let here = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let source = (try? String(contentsOf: here.appendingPathComponent("probe.js"), encoding: .utf8)) ?? ""
let expected = ((try? String(contentsOf: here.appendingPathComponent("node.txt"), encoding: .utf8)) ?? "")
    .trimmingCharacters(in: .whitespacesAndNewlines)
let engine = NodeEngine(root: here, env: [:])
let mine = await engine.run(source: source, path: "/probe.js", argv: ["node", "/probe.js"], cwd: "/", stdin: "")
let ours = mine.out.trimmingCharacters(in: .whitespacesAndNewlines)
let a = expected.split(separator: "\n").map(String.init), b = ours.split(separator: "\n").map(String.init)
var bad = 0
for i in 0..<max(a.count, b.count) {
    let want = i < a.count ? a[i] : "<missing>", got = i < b.count ? b[i] : "<missing>"
    if want != got { print("  node: \(want)\n  ours: \(got)"); bad += 1 }
}
if bad == 0 && !ours.isEmpty { print("MOVED PORT MATCH — all \(a.count) identical to node, including start() gating") }
else { print("MOVED PORT DIFFERS — \(bad)")
       if !mine.err.isEmpty { print("stderr: \(mine.err.prefix(300))") }; exit(1) }
