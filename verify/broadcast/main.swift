import Foundation
setvbuf(stdout, nil, _IONBF, 0)

// BroadcastChannel and receiveMessageOnPort: both were refused for needing shared memory, and
// neither does. One is a name registry with fan-out; the other pops a queue a port already has.
let realNode = "/Users/thyfriendlyfox/.local/bin/node"
let here = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

func nodeRun(_ file: String) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: realNode)
    p.arguments = [file]
    p.currentDirectoryURL = here
    let out = Pipe()
    p.standardOutput = out
    p.standardError = Pipe()
    try? p.run()
    let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    p.waitUntilExit()
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
}

var failures = 0
for (file, rounds) in [("probe.js", 3), ("cross.js", 8), ("hold.js", 6), ("envdata.js", 5), ("dual.js", 4), ("order.js", 4)] {
    let expected = nodeRun(file)
    print("--- node \(file) ---\n\(expected)")
    let source = (try? String(contentsOf: here.appendingPathComponent(file), encoding: .utf8)) ?? ""
    var bad = 0
    for round in 1...rounds {
        let engine = NodeEngine(root: here, env: ["PATH": "/usr/bin"])
        let mine = await engine.run(source: source, path: here.appendingPathComponent(file).path,
                                    argv: ["node", file], cwd: here.path, stdin: "")
        let ours = mine.out.trimmingCharacters(in: .whitespacesAndNewlines)
        if ours != expected {
            bad += 1; failures += 1
            print("\(file) round \(round): DIFFERS (status \(mine.status))")
            let a = expected.split(separator: "\n").map(String.init)
            let b = ours.split(separator: "\n").map(String.init)
            for i in 0..<max(a.count, b.count) {
                let x = i < a.count ? a[i] : "<missing>"
                let y = i < b.count ? b[i] : "<missing>"
                print(x == y ? "  = \(x)" : "  node: \(x)\n  ours: \(y)")
            }
            if !mine.err.isEmpty { print("  stderr: \(mine.err.prefix(500))") }
        }
    }
    print(bad == 0 ? "\(file): \(rounds)/\(rounds) identical to real node" : "\(file): \(bad)/\(rounds) DIFFERED")
}
print(failures == 0 ? "BROADCAST MATCH" : "BROADCAST MISMATCH (\(failures))")
exit(failures == 0 ? 0 : 1)
