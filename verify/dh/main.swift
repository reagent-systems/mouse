import Foundation
setvbuf(stdout, nil, _IONBF, 0)

// crypto.diffieHellman is node's KEY OBJECT agreement — X25519 and the EC curves — not
// finite-field DH. The old refusal named the wrong function. Proven two ways: both halves inside
// one engine, and a CROSS-ENGINE exchange where node and this engine each hold half the pair, so
// a matching secret cannot be a private convention.
let node = "/Users/thyfriendlyfox/.local/bin/node"
let here = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

func runNode(_ args: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: node)
    p.arguments = args
    p.currentDirectoryURL = here
    let out = Pipe()
    p.standardOutput = out
    p.standardError = Pipe()
    try? p.run()
    let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    p.waitUntilExit()
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
}

func runOurs(_ file: String, _ argv: [String] = []) async -> NodeEngine.Result {
    let source = (try? String(contentsOf: here.appendingPathComponent(file), encoding: .utf8)) ?? ""
    let engine = NodeEngine(root: here, env: ["PATH": "/usr/bin"])
    return await engine.run(source: source, path: "/" + file,
                            argv: ["node", "/" + file] + argv, cwd: "/", stdin: "")
}

var failures = 0

// 1. Both halves in one engine, every curve.
let expected = runNode(["local.js"])
let local = await runOurs("local.js")
if local.out.trimmingCharacters(in: .whitespacesAndNewlines) == expected {
    print("local agreement matches node:\n\(expected)")
} else {
    failures += 1
    print("LOCAL DIFFERS\n  node:\n\(expected)\n  ours:\n\(local.out)")
    if !local.err.isEmpty { print("  stderr: \(local.err.prefix(500))") }
}

// 2. Cross-engine, per curve: each side generates, each computes, the secrets must agree.
for type in ["x25519", "ec"] {
    _ = runNode(["gen.js", type, "peer"])                       // node's pair
    let ourGen = await runOurs("gen.js", [type, "mine"])         // ours
    if !ourGen.err.isEmpty { print("gen stderr: \(ourGen.err.prefix(400))") }

    let nodeSide = runNode(["agree.js", "peer.key", "mine.pub"])
    let ourSide = await runOurs("agree.js", ["/mine.key", "/peer.pub"])
    let ours = ourSide.out.trimmingCharacters(in: .whitespacesAndNewlines)

    if !ours.isEmpty, ours == nodeSide {
        print("\(type) cross-engine: both sides derived the same secret (\(ours.prefix(16))…)")
    } else {
        failures += 1
        print("\(type) CROSS-ENGINE DIFFERS\n  node: \(nodeSide)\n  ours: \(ours)")
        if !ourSide.err.isEmpty { print("  stderr: \(ourSide.err.prefix(500))") }
    }
}
print(failures == 0 ? "DIFFIE-HELLMAN MATCH" : "DIFFIE-HELLMAN MISMATCH (\(failures))")
exit(failures == 0 ? 0 : 1)
