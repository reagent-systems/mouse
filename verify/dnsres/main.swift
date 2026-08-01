import Foundation
setvbuf(stdout, nil, _IONBF, 0)

// The dns.resolve* family: node asks a DNS SERVER for a specific record type, which is why these
// were absent while dns.lookup (getaddrinfo) was always real. Live records, so the comparison is
// against what the internet actually returns — and against node reading the same answers.
let node = "/Users/thyfriendlyfox/.local/bin/node"
let here = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let source = (try? String(contentsOf: here.appendingPathComponent("script.js"), encoding: .utf8)) ?? ""

let p = Process()
p.executableURL = URL(fileURLWithPath: node)
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
if !mine.err.isEmpty { print("stderr: \(mine.err.prefix(700))") }

if ours == expected, !ours.isEmpty {
    print("DNS RESOLVERS MATCH — every record type identical to real node")
    print(ours)
} else {
    print("DNS RESOLVERS DIFFER")
    let a = expected.split(separator: "\n").map(String.init)
    let b = ours.split(separator: "\n").map(String.init)
    for i in 0..<max(a.count, b.count) {
        let x = i < a.count ? a[i] : "<missing>"
        let y = i < b.count ? b[i] : "<missing>"
        print(x == y ? "  = \(x)" : "  node: \(x)\n  ours: \(y)")
    }
    exit(1)
}
