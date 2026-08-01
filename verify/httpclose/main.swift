import Foundation
setvbuf(stdout, nil, _IONBF, 0)

// http.Server's connection management. The two methods differ on purpose: an in-flight request
// survives closeIdleConnections and dies to closeAllConnections, which is the difference between
// draining keep-alive clients and refusing to wait for a slow handler.
let here = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let source = (try? String(contentsOf: here.appendingPathComponent("script.js"), encoding: .utf8)) ?? ""

let p = Process()
p.executableURL = URL(fileURLWithPath: "/Users/thyfriendlyfox/.local/bin/node")
p.arguments = ["script.js"]
p.currentDirectoryURL = here
let out = Pipe()
p.standardOutput = out
p.standardError = Pipe()
try? p.run()
let expected = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    .trimmingCharacters(in: .whitespacesAndNewlines)
p.waitUntilExit()

var failures = 0
for round in 1...5 {
    let engine = NodeEngine(root: here, env: ["PATH": "/usr/bin"])
    let mine = await engine.run(source: source, path: "/script.js",
                                argv: ["node", "/script.js"], cwd: "/", stdin: "")
    let ours = mine.out.trimmingCharacters(in: .whitespacesAndNewlines)
    if ours != expected {
        failures += 1
        print("round \(round) DIFFERS\n  node:\n\(expected)\n  ours:\n\(ours)")
        if !mine.err.isEmpty { print("  stderr: \(mine.err.prefix(500))") }
        break
    }
}
print(failures == 0 ? "HTTP CLOSE MATCH — 5/5 rounds identical\n\(expected)" : "HTTP CLOSE MISMATCH")
exit(failures == 0 ? 0 : 1)
