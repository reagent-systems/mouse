import Foundation
setvbuf(stdout, nil, _IONBF, 0)
// The public APIs the module-surface audit had been naming as missing. It was right about
// BrotliCompress, so the rest of its list earned a look: MIMEType/MIMEParams, parseEnv,
// getCallSites and diff are documented API, not the internals they sat next to.
let here = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let source = (try? String(contentsOf: here.appendingPathComponent("probe.js"), encoding: .utf8)) ?? ""
let expected = ((try? String(contentsOf: here.appendingPathComponent("node.txt"), encoding: .utf8)) ?? "")
    .trimmingCharacters(in: .whitespacesAndNewlines)
let engine = NodeEngine(root: here, env: [:])
let mine = await engine.run(source: source, path: "/probe.js", argv: ["node", "/probe.js"], cwd: "/", stdin: "")
let ours = mine.out.trimmingCharacters(in: .whitespacesAndNewlines)
var oursBy: [String: String] = [:]
for line in ours.split(separator: "\n").map(String.init) {
    if let r = line.range(of: ": ") { oursBy[String(line[..<r.lowerBound])] = String(line[r.upperBound...]) }
}
var bad = 0
let want = expected.split(separator: "\n").map(String.init)
for line in want {
    guard let r = line.range(of: ": ") else { continue }
    let label = String(line[..<r.lowerBound]), value = String(line[r.upperBound...])
    let got = oursBy[label] ?? "<missing>"
    // getCallSites values are engine-specific; the CONTRACT is that frames exist with node's keys.
    if label == "callSites" { if got != value { print("  \(label): node=\(value) ours=\(got)"); bad += 1 }; continue }
    if got != value { print("  \(label): node=\(value) ours=\(got)"); bad += 1 }
}
if bad == 0 && !ours.isEmpty { print("UTIL SURFACE MATCH — all \(want.count) behaviours identical to node") }
else { print("UTIL SURFACE MISMATCH — \(bad) of \(want.count)")
       if !mine.err.isEmpty { print("stderr: \(mine.err.prefix(400))") }; exit(1) }
