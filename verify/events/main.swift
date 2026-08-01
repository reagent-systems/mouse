import Foundation
setvbuf(stdout, nil, _IONBF, 0)

// The EVENT SEQUENCE audit. Real code WAITS on events, so one that never fires is a hang and one
// that fires twice is a double-free; ordering matters too ('end' before 'close', 'response'
// before 'end'). Two event bugs have already turned up this session by accident — a duplicate
// 'close' on a Duplex and a lost 'end' — which is the argument for sweeping the class.
// ONE line in node.txt is pinned to OUR value: gzip emits its header chunk after 'finish',
// because our coder produces its output at the flush where node's produces some of it during the
// write. It is a tick-level ordering with no consequence for a caller doing one thing per event.
// Pinned rather than left red — a test that always fails protects nothing, and permanent
// failures are how a real one hides. The server line used to be pinned too; the stream lifecycle
// work made it agree with real node, so it is asserted against node's own output again.
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
print(wrong == 0 ? "\nEVENT SEQUENCES MATCH — all \(a.count)" : "\n\(wrong) SEQUENCES DIFFER")
