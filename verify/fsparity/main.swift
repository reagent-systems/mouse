import Foundation
setvbuf(stdout, nil, _IONBF, 0)

// SYNC/ASYNC/PROMISE parity. The sync fs functions were made much stricter a few boundaries ago —
// ENOENT for a missing parent, EEXIST, ENOTDIR, refusing to delete a tree — and whether the
// callback and promise forms followed was never checked. Three APIs for one operation is three
// chances to diverge, and a program that uses the promise form would not have noticed.
let here = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let source = (try? String(contentsOf: here.appendingPathComponent("script.js"), encoding: .utf8)) ?? ""
let expected = ((try? String(contentsOf: here.appendingPathComponent("node.txt"), encoding: .utf8)) ?? "")
    .trimmingCharacters(in: .whitespacesAndNewlines)

let engine = NodeEngine(root: here, env: ["PATH": "/usr/bin"])
let mine = await engine.run(source: source, path: "/script.js",
                            argv: ["node", "/script.js"], cwd: "/", stdin: "")
let ours = mine.out.trimmingCharacters(in: .whitespacesAndNewlines)
if !mine.err.isEmpty { print("stderr: \(mine.err.prefix(400))") }

let a = expected.split(separator: "\n").map(String.init)
let b = ours.split(separator: "\n").map(String.init)
var wrong = 0
var internallyInconsistent = 0
for i in 0..<max(a.count, b.count) {
    let x = i < a.count ? a[i] : "<missing>"
    let y = i < b.count ? b[i] : "<missing>"
    if y.contains("DIVERGES") { internallyInconsistent += 1 }
    if x == y { print("  ok   \(x)") } else { wrong += 1; print("  WRONG node: \(x)\n        ours: \(y)") }
}
if internallyInconsistent > 0 {
    print("\n\(internallyInconsistent) of our own operations disagree ACROSS their three forms")
}
print(wrong == 0 ? "\nFS PARITY MATCHES — all \(a.count)" : "\n\(wrong) DIFFER")
