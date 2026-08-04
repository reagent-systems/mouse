import Foundation
setvbuf(stdout, nil, _IONBF, 0)
// Every line here is a PROPERTY, not a reading: CPU counters differ every run, so what is
// asserted is that they have node's shape, are non-zero, and ADVANCE — a stub returning zeros
// passes a shape check, which is exactly what cpuUsage was doing.
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
    if got != value { print("  \(label): node=\(value) ours=\(got)"); bad += 1 }
}
// The two that cannot work here must refuse BY NAME, not return undefined.
let refusals = """
for (const name of ['dlopen', 'execve']) {
  try { process[name](); console.log(name + ': NO THROW'); }
  catch (e) { console.log(name + ': ' + (e.message.length > 30 && e.code ? 'names a reason' : 'terse')); }
}
"""
let e2 = NodeEngine(root: here, env: [:])
let refusalRun = await e2.run(source: refusals, path: "/r.js", argv: ["node"], cwd: "/", stdin: "")
for line in refusalRun.out.split(separator: "\n").map(String.init) {
    if !line.hasSuffix("names a reason") { print("  refusal weak: \(line)"); bad += 1 }
}
if bad == 0 && !ours.isEmpty {
    print("PROCESS SURFACE MATCH — all \(want.count) behaviours, and both refusals name a reason")
} else {
    print("PROCESS SURFACE MISMATCH — \(bad)")
    if !mine.err.isEmpty { print("stderr: \(mine.err.prefix(400))") }
    exit(1)
}
