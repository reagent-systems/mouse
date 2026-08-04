import Foundation
setvbuf(stdout, nil, _IONBF, 0)

// A `.node` file is compiled machine code, loaded by node through dlopen. iOS will not map new
// executable pages, so this is one of the platform's real walls — and what matters is that the
// wall says so. Reported as MODULE_NOT_FOUND it looked like a broken install, which sends people
// deleting node_modules over something no reinstall can fix.
//
// Real node is the peer here too: given the same tree it also fails, with the same ERROR CODE,
// because a hand-written Mach-O stub is not a loadable addon there either. The codes are what
// get compared; the message is each platform's own.

let realNode = "/Users/thyfriendlyfox/.local/bin/node"
let base = FileManager.default.temporaryDirectory.appendingPathComponent("nativeaddon-\(getpid())")
let pkg = base.appendingPathComponent("node_modules/nativey/build")
try? FileManager.default.createDirectory(at: pkg, withIntermediateDirectories: true)
func put(_ text: String, _ path: String) {
    try? text.write(to: base.appendingPathComponent(path), atomically: true, encoding: .utf8)
}
put(#"{ "name": "nativey", "main": "index.js" }"#, "node_modules/nativey/package.json")
put("module.exports = require('./build/thing.node');\n", "node_modules/nativey/index.js")
try? Data([0xcf, 0xfa, 0xed, 0xfe, 0x0c, 0x00, 0x00, 0x01, 0x02, 0x00, 0x00, 0x00])
    .write(to: pkg.appendingPathComponent("thing.node"))

let script = """
function code(run) {
  try { run(); return 'NO ERROR'; } catch (error) { return error.code || error.message.slice(0, 30); }
}
console.log('require package ->', code(() => require('nativey')));
console.log('require .node directly ->', code(() => require('./node_modules/nativey/build/thing.node')));
console.log('require without extension ->', code(() => require('./node_modules/nativey/build/thing')));
console.log('require.resolve finds it ->', require.resolve('./node_modules/nativey/build/thing.node').endsWith('/thing.node'));
console.log('a genuinely missing module ->', code(() => require('./nope.js')));
console.log('process.dlopen ->', code(() => process.dlopen({ exports: {} }, './node_modules/nativey/build/thing.node')));
"""
put(script, "probe.cjs")

let process = Process()
process.executableURL = URL(fileURLWithPath: realNode)
process.arguments = ["probe.cjs"]
process.currentDirectoryURL = base
let out = Pipe(), err = Pipe()
process.standardOutput = out
process.standardError = err
try? process.run()
let realText = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
_ = err.fileHandleForReading.readDataToEndOfFile()
process.waitUntilExit()

let engine = NodeEngine(root: base, env: ["PATH": "/"])
let ours = await engine.run(source: script, path: "/probe.cjs", argv: ["node", "/probe.cjs"], cwd: "/", stdin: "")

print("---- ours ----\n\(ours.out)---- real ----\n\(realText)")
if !ours.err.isEmpty { print("ours stderr: \(ours.err.prefix(400))") }

// And the message has to NAME the file — a true reason nobody can act on is half a refusal.
let named = await engine.run(source: """
    try { require('nativey'); } catch (error) { console.log(error.message); }
    """, path: "/named.cjs", argv: ["node", "/named.cjs"], cwd: "/", stdin: "")

if ours.out == realText, named.out.contains("thing.node"), named.out.contains("executable pages") {
    print("NATIVE ADDON MATCH — every outcome carries the code real node carries, and the refusal names the file")
} else {
    print("MISMATCH: native addon handling (message was \(named.out.debugDescription))")
    exit(1)
}
try? FileManager.default.removeItem(at: base)
