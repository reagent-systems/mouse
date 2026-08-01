import Foundation
setvbuf(stdout, nil, _IONBF, 0)

// brotli was refused as "not built into this device". Compression framework has shipped
// COMPRESSION_BROTLI since iOS 15 — found by a surface sweep, not by a package failing.
// Compressed BYTES need not match node's (different encoder settings), so the property proven
// here is the one that matters: each engine reads what the other writes.
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
let phrase = "the sweep found this, not a package failing"

// 1. Everything inside one engine, including the streaming forms.
let expected = runNode(["local.js"])
let local = await runOurs("local.js")
let ours = local.out.trimmingCharacters(in: .whitespacesAndNewlines)
if ours == expected {
    print("local brotli matches node:\n\(expected)")
} else {
    failures += 1
    print("LOCAL DIFFERS\n  node:\n\(expected)\n  ours:\n\(ours)")
    if !local.err.isEmpty { print("  stderr: \(local.err.prefix(600))") }
}

// 2. Ours compresses, node reads it.
let packed = await runOurs("pack.js", [phrase, "/ours.br"])
if !packed.err.isEmpty { print("pack stderr: \(packed.err.prefix(300))") }
let nodeRead = runNode(["unpack.js", "ours.br"])
if nodeRead == phrase {
    print("node decompressed OUR brotli stream")
} else {
    failures += 1
    print("node could not read ours: \(nodeRead.debugDescription)")
}

// 3. node compresses, ours reads it.
_ = runNode(["pack.js", phrase, "node.br"])
let oursRead = await runOurs("unpack.js", ["/node.br"])
let text = oursRead.out.trimmingCharacters(in: .whitespacesAndNewlines)
if text == phrase {
    print("our engine decompressed NODE's brotli stream")
} else {
    failures += 1
    print("ours could not read node's: \(text.debugDescription)")
    if !oursRead.err.isEmpty { print("  stderr: \(oursRead.err.prefix(400))") }
}

print(failures == 0 ? "BROTLI MATCH — interoperable both directions" : "BROTLI MISMATCH (\(failures))")
exit(failures == 0 ? 0 : 1)
