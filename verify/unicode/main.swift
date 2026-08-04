import Foundation
setvbuf(stdout, nil, _IONBF, 0)
// Byte-vs-character confusion is the silent-corruption class for an editor: an emoji is two
// UTF-16 units and four bytes, a combining mark is a second code point, and any place that
// treats one as the other loses user text without reporting anything.
let here = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
try? FileManager.default.removeItem(at: here.appendingPathComponent("u"))
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
if bad == 0 && !ours.isEmpty { print("UNICODE MATCH — all \(a.count) lines identical to node") }
else { print("UNICODE DIFFERS — \(bad) of \(a.count)")
       if !mine.err.isEmpty { print("stderr: \(mine.err.prefix(400))") }; exit(1) }
