import Foundation
setvbuf(stdout, nil, _IONBF, 0)

// A monotonic clock cannot be gated by comparing readings — they differ every run. Every line
// the probe emits is a PROPERTY that must hold on both engines: never backwards, sub-millisecond,
// no negative field after a borrow, and the two clocks agreeing on one measured span.
let here = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let source = (try? String(contentsOf: here.appendingPathComponent("probe.js"), encoding: .utf8)) ?? ""
let expected = ((try? String(contentsOf: here.appendingPathComponent("node.txt"), encoding: .utf8)) ?? "")
    .trimmingCharacters(in: .whitespacesAndNewlines)

let engine = NodeEngine(root: here, env: [:])
let mine = await engine.run(source: source, path: "/probe.js",
                            argv: ["node", "/probe.js"], cwd: "/", stdin: "")
let ours = mine.out.trimmingCharacters(in: .whitespacesAndNewlines)

let a = expected.split(separator: "\n").map(String.init)
let b = ours.split(separator: "\n").map(String.init)
var bad = 0
// Key by label rather than by index: one divergence must not shift every later line.
var oursByLabel: [String: String] = [:]
for line in b { let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
                if parts.count == 2 { oursByLabel[parts[0]] = parts[1].trimmingCharacters(in: .whitespaces) } }
for line in a {
    let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
    guard parts.count == 2 else { continue }
    let label = parts[0], want = parts[1].trimmingCharacters(in: .whitespaces)
    let got = oursByLabel[label] ?? "<missing>"
    if got != want { print("  DIFFERS \(label): node=\(want) ours=\(got)"); bad += 1 }
}
if bad == 0 && !ours.isEmpty {
    print("HRTIME MATCH — \(a.count) clock properties hold on both engines")
} else {
    print("HRTIME FAILED — \(bad) properties differ")
    if !mine.err.isEmpty { print("stderr: \(mine.err.prefix(600))") }
    exit(1)
}
