import Foundation
setvbuf(stdout, nil, _IONBF, 0)

// Fourth detector: options ACCEPTED AND IGNORED. Invisible to the export, shape and globals
// sweeps — TextDecoder's dropped {stream:true} was exactly this shape of bug. Every option here
// has an OBSERVABLE effect, so being ignored shows up as a wrong answer rather than as silence.
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

let engine = NodeEngine(root: here, env: ["PATH": "/usr/bin"])
let mine = await engine.run(source: source, path: "/script.js",
                            argv: ["node", "/script.js"], cwd: "/", stdin: "")
let ours = mine.out.trimmingCharacters(in: .whitespacesAndNewlines)
if !mine.err.isEmpty { print("stderr: \(mine.err.prefix(500))") }

let a = expected.split(separator: "\n").map(String.init)
let b = ours.split(separator: "\n").map(String.init)
var wrong = 0
for i in 0..<max(a.count, b.count) {
    let x = i < a.count ? a[i] : "<missing>"
    let y = i < b.count ? b[i] : "<missing>"
    if x == y { print("  ok   \(x)") } else { wrong += 1; print("  WRONG node: \(x)\n        ours: \(y)") }
}
print(wrong == 0 ? "\nOPTIONS MATCH — all \(a.count) honoured" : "\n\(wrong) OPTIONS IGNORED OR WRONG")
