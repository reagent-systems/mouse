import Foundation
setvbuf(stdout, nil, _IONBF, 0)

// Hash, Hmac and Cipher are Transforms in node, and that is not decoration:
// `fs.createReadStream(f).pipe(hash)` is the ordinary way to hash a file, and it could not work
// while these were plain objects. The instance-shape sweep put this at the top of what was left.
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
for round in 1...4 {
    let engine = NodeEngine(root: here, env: ["PATH": "/usr/bin"])
    let mine = await engine.run(source: source, path: "/script.js",
                                argv: ["node", "/script.js"], cwd: "/", stdin: "")
    let ours = mine.out.trimmingCharacters(in: .whitespacesAndNewlines)
    if ours != expected {
        failures += 1
        print("round \(round) DIFFERS")
        let a = expected.split(separator: "\n").map(String.init)
        let b = ours.split(separator: "\n").map(String.init)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : "<missing>"
            let y = i < b.count ? b[i] : "<missing>"
            print(x == y ? "  = \(x)" : "  node: \(x)\n  ours: \(y)")
        }
        if !mine.err.isEmpty { print("  stderr: \(mine.err.prefix(600))") }
        break
    }
}
print(failures == 0 ? "CRYPTO STREAMS MATCH — 4/4 rounds identical to real node\n\(expected)"
                    : "CRYPTO STREAMS MISMATCH")
exit(failures == 0 ? 0 : 1)
