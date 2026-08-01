import Foundation
setvbuf(stdout, nil, _IONBF, 0)
// The error-path events: they fire only when something goes wrong, which makes them the ones
// least likely to exist and the most costly to be missing. A server that cannot report a
// malformed request or a taken port fails silently instead of loudly.
let here = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let source = (try? String(contentsOf: here.appendingPathComponent("probe.js"), encoding: .utf8)) ?? ""
let expected = ((try? String(contentsOf: here.appendingPathComponent("node.txt"), encoding: .utf8)) ?? "")
    .trimmingCharacters(in: .whitespacesAndNewlines)
let engine = NodeEngine(root: here, env: ["PATH": "/usr/bin"])
let mine = await engine.run(source: source, path: "/probe.js", argv: ["node", "/probe.js"], cwd: "/", stdin: "")
let ours = mine.out.trimmingCharacters(in: .whitespacesAndNewlines)
let a = expected.split(separator: "\n").map(String.init), b = ours.split(separator: "\n").map(String.init)
var bad = 0
for i in 0..<max(a.count, b.count) {
    let want = i < a.count ? a[i] : "<missing>", got = i < b.count ? b[i] : "<missing>"
    if want != got { print("  node: \(want)\n  ours: \(got)"); bad += 1 }
}
if bad == 0 && !ours.isEmpty { print("NET ERROR EVENTS MATCH — all \(a.count), including the 400 a bad request gets") }
else { print("NET ERROR EVENTS DIFFER — \(bad)")
       if !mine.err.isEmpty { print("stderr: \(mine.err.prefix(300))") }; exit(1) }
