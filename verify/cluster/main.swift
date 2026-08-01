import Foundation
setvbuf(stdout, nil, _IONBF, 0)

// cluster: the primary owns the one listening socket and hands accepted DESCRIPTORS to workers.
// Real node passes them with SCM_RIGHTS between processes; here the workers are engines inside
// ONE process, so the descriptor is already valid and only its number crosses the channel.
let realNode = "/Users/thyfriendlyfox/.local/bin/node"
let here = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let script = (try? String(contentsOf: here.appendingPathComponent("server.js"), encoding: .utf8)) ?? ""
let basePort = 23000 + Int(getpid() % 700)

func runNode(_ port: Int) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: realNode)
    p.arguments = ["server.js"]
    p.currentDirectoryURL = here
    var e = ProcessInfo.processInfo.environment
    e["CLUSTER_PORT"] = String(port)
    e["NO_KILL"] = ProcessInfo.processInfo.environment["NO_KILL"] ?? ""
    e["PROBE_NO_AGENT"] = ProcessInfo.processInfo.environment["PROBE_NO_AGENT"] ?? ""
    p.environment = e
    let out = Pipe()
    p.standardOutput = out
    p.standardError = Pipe()
    try? p.run()
    let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    p.waitUntilExit()
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
}

let expected = runNode(basePort)
print("--- node ---\n\(expected)")

// Repeated, because a green run on a concurrent path is not evidence: every socket-teardown bug
// in this layer failed roughly one run in three.
let rounds = Int(ProcessInfo.processInfo.environment["ROUNDS"] ?? "20") ?? 20
var failures = 0
for round in 1...rounds {
    let engine = NodeEngine(root: here, env: ["CLUSTER_PORT": String(basePort + round * 3), "PATH": "/usr/bin",
                                             "NO_KILL": ProcessInfo.processInfo.environment["NO_KILL"] ?? "",
                                             "PROBE_NO_AGENT": ProcessInfo.processInfo.environment["PROBE_NO_AGENT"] ?? ""])
    let mine = await engine.run(source: script, path: here.appendingPathComponent("server.js").path,
                                argv: ["node", "server.js"], cwd: here.path, stdin: "")
    let ours = mine.out.trimmingCharacters(in: .whitespacesAndNewlines)
    if ours == expected {
        print("round \(round): IDENTICAL to real node (status \(mine.status))")
    } else {
        failures += 1
        print("round \(round): DIFFERS (status \(mine.status))")
        let a = expected.split(separator: "\n").map(String.init)
        let b = ours.split(separator: "\n").map(String.init)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : "<missing>"
            let y = i < b.count ? b[i] : "<missing>"
            print(x == y ? "  = \(x)" : "  node: \(x)\n  ours: \(y)")
        }
        if !mine.err.isEmpty { print("  stderr: \(mine.err.prefix(400))") }
    }
}
print(failures == 0 ? "CLUSTER MATCH — \(rounds)/\(rounds) rounds identical to real node"
                    : "CLUSTER MISMATCH — \(failures)/\(rounds) rounds differed")
exit(failures == 0 ? 0 : 1)
