import Foundation
setvbuf(stdout, nil, _IONBF, 0)

// fs.globSync against real node on a real tree — the API programs actually call, and the one
// whose reference behaviour is self-consistent (unlike path.matchesGlob, see the corpus).
let here = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let source = (try? String(contentsOf: here.appendingPathComponent("walk.js"), encoding: .utf8)) ?? ""

let p = Process()
p.executableURL = URL(fileURLWithPath: "/Users/thyfriendlyfox/.local/bin/node")
p.arguments = ["walk.js"]
p.currentDirectoryURL = here
let out = Pipe()
p.standardOutput = out
p.standardError = Pipe()
try? p.run()
let expected = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    .trimmingCharacters(in: .whitespacesAndNewlines)
p.waitUntilExit()

let engine = NodeEngine(root: here, env: ["PATH": "/usr/bin"])
let mine = await engine.run(source: source, path: "/walk.js",
                            argv: ["node", "/walk.js"], cwd: "/", stdin: "")
let ours = mine.out.trimmingCharacters(in: .whitespacesAndNewlines)
if !mine.err.isEmpty { print("stderr: \(mine.err.prefix(500))") }

if ours == expected {
    print("GLOB WALK MATCH — every pattern returned node's exact file list")
    print(ours)
} else {
    print("GLOB WALK DIFFERS")
    let a = expected.split(separator: "\n").map(String.init)
    let b = ours.split(separator: "\n").map(String.init)
    for i in 0..<max(a.count, b.count) {
        let x = i < a.count ? a[i] : "<missing>"
        let y = i < b.count ? b[i] : "<missing>"
        print(x == y ? "  = \(x)" : "  node: \(x)\n  ours: \(y)")
    }
    exit(1)
}
