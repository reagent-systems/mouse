import Foundation
setvbuf(stdout, nil, _IONBF, 0)

// The globals sweep's useful finding: TextDecoderStream/TextEncoderStream were absent, and
// `response.body.pipeThrough(new TextDecoderStream())` is how a fetch body is read as text
// without buffering it all. The discriminating case is a character split across chunks.
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

if ours == expected, !ours.isEmpty {
    print("TEXT STREAMS MATCH — \(expected.split(separator: "\n").count) lines identical to real node")
} else {
    print("TEXT STREAMS DIFFER")
    let a = expected.split(separator: "\n").map(String.init)
    let b = ours.split(separator: "\n").map(String.init)
    for i in 0..<max(a.count, b.count) {
        let x = i < a.count ? a[i] : "<missing>"
        let y = i < b.count ? b[i] : "<missing>"
        print(x == y ? "  = \(x)" : "  node: \(x)\n  ours: \(y)")
    }
    exit(1)
}
