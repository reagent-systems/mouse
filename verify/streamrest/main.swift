import Foundation
setvbuf(stdout, nil, _IONBF, 0)

extension String {
    func stripIndent() -> String {
        split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.hasPrefix("    ") ? String($0.dropFirst(4)) : String($0) }
            .joined(separator: "\n")
    }
}

// What the instance-shape sweep left on the stream classes. `unpipe` is the one that matters:
// real code stops a pipe mid-flight — proxying, tar, aborting a download — and today that is a
// TypeError rather than a stopped pipe.
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
for i in 0..<max(a.count, b.count) {
    let x = i < a.count ? a[i] : "<missing>"
    let y = i < b.count ? b[i] : "<missing>"
    if x == y { print("  ok   \(x)") } else { wrong += 1; print("  WRONG node: \(x)\n        ours: \(y)") }
}
print(wrong == 0 ? "\nSTREAM SURFACE MATCHES — all \(a.count)" : "\n\(wrong) DIFFER")
