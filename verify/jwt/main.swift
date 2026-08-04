import Foundation

/// See the nodejs harness: stripping "    " everywhere also eats four-space runs inside the
/// expected text. This content has none today, but the trap should not be left armed.
extension String {
    func stripIndent() -> String {
        split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.hasPrefix("    ") ? String($0.dropFirst(4)) : String($0) }
            .joined(separator: "\n")
    }
}
setvbuf(stdout, nil, _IONBF, 0)

// Real-package proof for signing: jsonwebtoken, the JWT library everything uses. ES256 is
// ECDSA P-256 with the signature re-encoded from DER to JOSE's raw r||s (jsonwebtoken does
// that through ecdsa-sig-formatter), and HS256 is HMAC — so this exercises the new signing
// path AND the old digest path through code nobody wrote for us. Cross-engine: a token signed
// here must verify under real node, and the reverse.

let realNode = "/Users/thyfriendlyfox/.local/bin/node"
let base = FileManager.default.temporaryDirectory.appendingPathComponent("jwt-\(getpid())")
try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

print("installing jsonwebtoken with our own package manager…")
do { _ = try await PackageManager.install(requirements: ["jsonwebtoken": "^9.0.2"], into: base) }
catch { print("FAIL: install: \(error)"); exit(1) }

let signScript = """
const jwt = require('jsonwebtoken');
const crypto = require('crypto');
const fs = require('fs');
const { publicKey, privateKey } = crypto.generateKeyPairSync('ec', {
  namedCurve: 'prime256v1',
  publicKeyEncoding: { type: 'spki', format: 'pem' },
  privateKeyEncoding: { type: 'pkcs8', format: 'pem' },
});
const payload = { sub: 'mouse', scope: 'phase-g' };
const es256 = jwt.sign(payload, privateKey, { algorithm: 'ES256', noTimestamp: true });
const hs256 = jwt.sign(payload, 'a shared secret', { algorithm: 'HS256', noTimestamp: true });
const rsa = crypto.generateKeyPairSync('rsa', {
  modulusLength: 2048,
  publicKeyEncoding: { type: 'spki', format: 'pem' },
  privateKeyEncoding: { type: 'pkcs8', format: 'pem' },
});
const rs256 = jwt.sign(payload, rsa.privateKey, { algorithm: 'RS256', noTimestamp: true });
const ps256 = jwt.sign(payload, rsa.privateKey, { algorithm: 'PS256', noTimestamp: true });
fs.writeFileSync('tokens.json', JSON.stringify({ publicKey, es256, hs256, rs256, ps256, rsaPublic: rsa.publicKey }));
console.log('signed ES256, HS256, RS256 and PS256; segments:',
            es256.split('.').length, hs256.split('.').length, rs256.split('.').length);
"""

let verifyScript = """
const jwt = require('jsonwebtoken');
const fs = require('fs');
const { publicKey, es256, hs256, rs256, ps256, rsaPublic } = JSON.parse(fs.readFileSync('tokens.json', 'utf8'));
const fromES = jwt.verify(es256, publicKey, { algorithms: ['ES256'] });
const fromHS = jwt.verify(hs256, 'a shared secret', { algorithms: ['HS256'] });
const fromRS = jwt.verify(rs256, rsaPublic, { algorithms: ['RS256'] });
const fromPS = jwt.verify(ps256, rsaPublic, { algorithms: ['PS256'] });
console.log('ES256 payload:', JSON.stringify(fromES));
console.log('HS256 payload:', JSON.stringify(fromHS));
console.log('RS256 payload:', JSON.stringify(fromRS));
console.log('PS256 payload:', JSON.stringify(fromPS));
// A tampered payload must fail, or "verified" means nothing.
const parts = es256.split('.');
const tampered = parts[0] + '.' + Buffer.from(JSON.stringify({ sub: 'attacker' })).toString('base64url') + '.' + parts[2];
try { jwt.verify(tampered, publicKey, { algorithms: ['ES256'] }); console.log('UNEXPECTED: tampered token verified'); }
catch (error) { console.log('tampered token rejected:', error.name); }
"""

func write(_ text: String, _ name: String, _ dir: URL) {
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try? text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
}
func runReal(_ entry: String, _ dir: URL) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: realNode)
    process.arguments = [entry]
    process.currentDirectoryURL = dir
    let out = Pipe(), err = Pipe()
    process.standardOutput = out
    process.standardError = err
    try? process.run()
    process.waitUntilExit()
    let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    let problems = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    if !problems.isEmpty { FileHandle.standardError.write("real stderr: \(problems)\n".data(using: .utf8)!) }
    return text
}
func runOurs(_ script: String, _ dir: URL, entry: String) async -> String {
    write(script, entry, dir)
    let engine = NodeEngine(root: dir, env: ["PATH": "/"])
    let result = await engine.run(source: script, path: "/" + entry, argv: ["node", "/" + entry],
                                  cwd: "/", stdin: "")
    if !result.err.isEmpty { FileHandle.standardError.write("ours stderr: \(result.err)\n".data(using: .utf8)!) }
    return result.out
}

// node_modules lives at the root; both engines run from there.
write(signScript, "sign.js", base)
write(verifyScript, "verify.js", base)

// ours signs → real node verifies
let signedByUs = await runOurs(signScript, base, entry: "sign.js")
let checkedByReal = runReal("verify.js", base)

// real node signs → ours verifies
let signedByReal = runReal("sign.js", base)
let checkedByUs = await runOurs(verifyScript, base, entry: "verify.js")

let expected = """
    ES256 payload: {"sub":"mouse","scope":"phase-g"}
    HS256 payload: {"sub":"mouse","scope":"phase-g"}
    RS256 payload: {"sub":"mouse","scope":"phase-g"}
    PS256 payload: {"sub":"mouse","scope":"phase-g"}
    tampered token rejected: JsonWebTokenError

    """.stripIndent()

if checkedByReal == expected, checkedByUs == expected, signedByUs == signedByReal {
    print("JWT MATCH — jsonwebtoken signs on our engine and real node verifies it, and the reverse:")
    print(checkedByUs, terminator: "")
} else {
    print("MISMATCH")
    print("  ours signed: \(signedByUs.debugDescription)")
    print("  real signed: \(signedByReal.debugDescription)")
    print("  real verified ours: \(checkedByReal.debugDescription)")
    print("  ours verified real's: \(checkedByUs.debugDescription)")
    exit(1)
}
try? FileManager.default.removeItem(at: base)
