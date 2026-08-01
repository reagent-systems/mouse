import Foundation
setvbuf(stdout, nil, _IONBF, 0)

// node drains the nextTick queue before ANY promise reaction — after I/O callbacks too, not
// only after timers. The trampoline covers timers, immediates and port deliveries; host EVENTS
// (fs completions, socket data) arrive through per-bridge closures, so this is what says whether
// that gap is real.
let realNode = "/Users/thyfriendlyfox/.local/bin/node"
let here = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let script = (try? String(contentsOf: here.appendingPathComponent("script.js"), encoding: .utf8)) ?? ""

let p = Process()
p.executableURL = URL(fileURLWithPath: realNode)
p.arguments = ["script.js"]
p.currentDirectoryURL = here
let out = Pipe()
p.standardOutput = out
p.standardError = Pipe()
try? p.run()
let expected = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    .trimmingCharacters(in: .whitespacesAndNewlines)
p.waitUntilExit()
print("node: \(expected)")

var failures = 0
for round in 1...6 {
    let engine = NodeEngine(root: here, env: ["PATH": "/usr/bin"])
    let mine = await engine.run(source: script, path: "/script.js",
                                argv: ["node", "/script.js"], cwd: "/", stdin: "")
    let ours = mine.out.trimmingCharacters(in: .whitespacesAndNewlines)
    if ours != expected {
        failures += 1
        print("round \(round): ours: \(ours)")
        if !mine.err.isEmpty { print("  stderr: \(mine.err.prefix(300))") }
    }
}
print(failures == 0 ? "IO ORDER MATCH — 6/6" : "IO ORDER MISMATCH — \(failures)/6")
exit(failures == 0 ? 0 : 1)
