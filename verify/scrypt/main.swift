import Foundation
setvbuf(stdout, nil, _IONBF, 0)

// scrypt was refused for having "no system implementation", which was true and beside the point:
// scrypt is PBKDF2 (which CommonCrypto has) around a memory-hard mix that is just arithmetic.
// The first three lines are RFC 7914's published vectors, so this is a match against the
// STANDARD, not only against node.
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

let started = Date()
let engine = NodeEngine(root: here, env: ["PATH": "/usr/bin"])
let mine = await engine.run(source: script, path: "/script.js",
                            argv: ["node", "/script.js"], cwd: "/", stdin: "")
let elapsed = Date().timeIntervalSince(started)
let ours = mine.out.trimmingCharacters(in: .whitespacesAndNewlines)

if ours == expected {
    print("SCRYPT MATCH — RFC 7914 vectors and node, byte for byte (\(String(format: "%.1f", elapsed))s)")
    print(ours)
} else {
    print("SCRYPT MISMATCH")
    let a = expected.split(separator: "\n").map(String.init)
    let b = ours.split(separator: "\n").map(String.init)
    for i in 0..<max(a.count, b.count) {
        let x = i < a.count ? a[i] : "<missing>"
        let y = i < b.count ? b[i] : "<missing>"
        print(x == y ? "  = \(x)" : "  node: \(x)\n  ours: \(y)")
    }
    if !mine.err.isEmpty { print("stderr: \(mine.err.prefix(600))") }
    exit(1)
}
