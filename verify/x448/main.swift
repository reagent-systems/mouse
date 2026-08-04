import Foundation
setvbuf(stdout, nil, _IONBF, 0)

// X448 was refused because "the system has no such key type" — true of the SYSTEM, and silent
// on whether it can be written. RFC 7748 is a Montgomery ladder over p = 2^448 - 2^224 - 1, and
// JSC's BigInt does the arithmetic. Same shape as scrypt and finite-field DH.
//
// The proof that matters is cross-engine: this engine and real node each generate a pair, and
// each derives the shared secret from the other's public half. Equal secrets means the curve
// arithmetic, the clamping and the DER encodings all agree — a self-check proves none of that.
let here = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

func runNode(_ script: String, _ args: [String]) -> [String] {
    let file = here.appendingPathComponent("peer.js")
    try? script.write(to: file, atomically: true, encoding: .utf8)
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/Users/thyfriendlyfox/.local/bin/node")
    task.arguments = [file.path] + args
    let pipe = Pipe(); task.standardOutput = pipe; task.standardError = Pipe()
    try? task.run(); task.waitUntilExit()
    return (String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
        .split(separator: "\n").map(String.init)
}

// 1. Our engine generates a pair and publishes both halves in PEM.
let e1 = NodeEngine(root: here, env: [:])
let step1 = await e1.run(source: """
const c = require('crypto');
const pair = c.generateKeyPairSync('x448', {
  publicKeyEncoding: { type: 'spki', format: 'pem' },
  privateKeyEncoding: { type: 'pkcs8', format: 'pem' },
});
console.log(JSON.stringify(pair.publicKey));
console.log(JSON.stringify(pair.privateKey));
""", path: "/s1.js", argv: ["node"], cwd: "/", stdin: "")
let ourLines = step1.out.split(separator: "\n").map(String.init)
guard ourLines.count >= 2 else { print("step 1 failed: \(step1.err.prefix(300))"); exit(1) }
let ourPublic = ourLines[0], ourPrivate = ourLines[1]

// 2. Real node: its own pair, and the secret derived from OUR public key.
let nodeLines = runNode("""
const c = require('crypto');
const pair = c.generateKeyPairSync('x448', {
  publicKeyEncoding: { type: 'spki', format: 'pem' },
  privateKeyEncoding: { type: 'pkcs8', format: 'pem' },
});
const theirs = c.createPublicKey(JSON.parse(process.argv[2]));
const secret = c.diffieHellman({ privateKey: c.createPrivateKey(pair.privateKey), publicKey: theirs });
console.log(JSON.stringify(pair.publicKey));
console.log(secret.toString('hex'));
""", [ourPublic])
guard nodeLines.count >= 2 else { print("node peer failed"); exit(1) }
let nodePublic = nodeLines[0], nodeSecret = nodeLines[1]

// 3. Our engine, same private key, against node's public half.
let e2 = NodeEngine(root: here, env: [:])
let step3 = await e2.run(source: """
const c = require('crypto');
const secret = c.diffieHellman({
  privateKey: c.createPrivateKey(JSON.parse(process.argv[2])),
  publicKey: c.createPublicKey(JSON.parse(process.argv[3])),
});
console.log(secret.toString('hex'));
""", path: "/s3.js", argv: ["node", "/s3.js", ourPrivate, nodePublic], cwd: "/", stdin: "")
let ourSecret = step3.out.trimmingCharacters(in: .whitespacesAndNewlines)

if ourSecret == nodeSecret, ourSecret.count == 112 {
    print("X448 CROSS-ENGINE MATCH — real node and this engine derived the SAME 56-byte secret")
    print("  from opposite halves of the exchange: \(ourSecret.prefix(32))…")
} else {
    print("X448 CROSS-ENGINE FAILED")
    print("  node: \(nodeSecret.prefix(64))")
    print("  ours: \(ourSecret.prefix(64))")
    if !step3.err.isEmpty { print("  stderr: \(step3.err.prefix(300))") }
    exit(1)
}
