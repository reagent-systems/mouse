import Foundation
setvbuf(stdout, nil, _IONBF, 0)

// Finite-field DH and primality were refused as "needs a bignum implementation". JavaScriptCore
// has had native BigInt all along — a 2048-bit modpow runs in about 2 ms — so the bignum was
// never missing. Two gates here: the deterministic properties, and then the one that actually
// matters, a CROSS-ENGINE exchange where real node and this engine derive the same shared
// secret from opposite halves of a key pair.
let here = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let source = (try? String(contentsOf: here.appendingPathComponent("probe.js"), encoding: .utf8)) ?? ""
let expected = ((try? String(contentsOf: here.appendingPathComponent("node.txt"), encoding: .utf8)) ?? "")
    .trimmingCharacters(in: .whitespacesAndNewlines)
let engine = NodeEngine(root: here, env: [:])
let mine = await engine.run(source: source, path: "/probe.js", argv: ["node", "/probe.js"], cwd: "/", stdin: "")
let ours = mine.out.trimmingCharacters(in: .whitespacesAndNewlines)

var bad = 0
let a = expected.split(separator: "\n").map(String.init), b = ours.split(separator: "\n").map(String.init)
for i in 0..<max(a.count, b.count) {
    let want = i < a.count ? a[i] : "<missing>", got = i < b.count ? b[i] : "<missing>"
    if want != got { print("  node: \(want)\n  ours: \(got)"); bad += 1 }
}
if bad > 0 {
    print("DH PROPERTIES DIFFER — \(bad) lines")
    if !mine.err.isEmpty { print("stderr: \(mine.err.prefix(700))") }
    exit(1)
}

// Cross-engine, done properly: OUR engine generates a pair and hands out its public half; real
// node derives a secret from it; then our engine recomputes with the SAME private key against
// node's public half. Equal secrets is the only thing that proves the arithmetic — matching
// lengths proves nothing, which an earlier version of this harness got wrong.
func runNode(_ script: String, _ args: [String]) -> [String] {
    let file = here.appendingPathComponent("peer.js")
    try? script.write(to: file, atomically: true, encoding: .utf8)
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/Users/thyfriendlyfox/.local/bin/node")
    task.arguments = [file.path] + args
    let pipe = Pipe(); task.standardOutput = pipe; task.standardError = Pipe()
    try? task.run(); task.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return (String(data: data, encoding: .utf8) ?? "").split(separator: "\n").map(String.init)
}

let group = "modp14"
// 1. Our engine: a fresh pair, publishing both halves so step 3 can reproduce it exactly.
let e2 = NodeEngine(root: here, env: [:])
let step1 = await e2.run(source: """
const c = require('crypto');
const d = c.getDiffieHellman('\(group)');
d.generateKeys();
console.log(d.getPublicKey().toString('hex'));
console.log(d.getPrivateKey().toString('hex'));
""", path: "/s1.js", argv: ["node", "/s1.js"], cwd: "/", stdin: "")
let ourLines = step1.out.split(separator: "\n").map(String.init)
guard ourLines.count >= 2 else { print("step 1 failed: \(step1.err.prefix(400))"); exit(1) }
let ourPublic = ourLines[0], ourPrivate = ourLines[1]

// 2. Real node: its own pair, and the secret derived from OUR public key.
let nodeLines = runNode("""
const c = require('crypto');
const d = c.getDiffieHellman('\(group)');
d.generateKeys();
console.log(d.getPublicKey().toString('hex'));
console.log(d.computeSecret(Buffer.from(process.argv[2], 'hex')).toString('hex'));
""", [ourPublic])
guard nodeLines.count >= 2 else { print("node peer failed"); exit(1) }
let nodePublic = nodeLines[0], nodeSecret = nodeLines[1]

// 3. Our engine again, same private key, against node's public half.
let e3 = NodeEngine(root: here, env: [:])
let step3 = await e3.run(source: """
const c = require('crypto');
const d = c.getDiffieHellman('\(group)');
d.setPrivateKey(Buffer.from(process.argv[2], 'hex'));
console.log(d.computeSecret(Buffer.from(process.argv[3], 'hex')).toString('hex'));
""", path: "/s3.js", argv: ["node", "/s3.js", ourPrivate, nodePublic], cwd: "/", stdin: "")
let ourSecret = step3.out.trimmingCharacters(in: .whitespacesAndNewlines)

if ourSecret == nodeSecret, ourSecret.count == 512 {
    print("DH PROPERTIES MATCH — all \(a.count) lines identical to node")
    print("CROSS-ENGINE MATCH — real node and this engine derived the SAME 2048-bit shared")
    print("  secret from opposite halves of the exchange: \(ourSecret.prefix(32))…")
} else {
    print("CROSS-ENGINE FAILED")
    print("  node secret: \(nodeSecret.prefix(64))")
    print("  our secret:  \(ourSecret.prefix(64))")
    if !step3.err.isEmpty { print("  stderr: \(step3.err.prefix(400))") }
    exit(1)
}
