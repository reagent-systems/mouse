import Foundation
setvbuf(stdout, nil, _IONBF, 0)

// A proactive surface audit, the method that has found gaps no package had reached yet: list
// what real node exports for a module and diff it against ours. Reported as three sets —
// missing (node has it, we do not), extra (we invented it), and present — so a real gap can
// be told from a deliberate omission.

let realNode = "/Users/thyfriendlyfox/.local/bin/node"
let base = FileManager.default.temporaryDirectory.appendingPathComponent("audit-\(getpid())")
try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

let modules = ["fs", "fs/promises", "path", "os", "util", "events", "stream", "buffer",
               "crypto", "zlib", "net", "http", "dns", "readline", "child_process",
               "url", "querystring", "string_decoder", "timers", "assert", "tty", "process"]

func script(for module: String) -> String {
    """
    const target = \(module == "fs/promises" ? "require('fs').promises" : "require('\(module)')");
    const names = new Set();
    for (const key of Object.keys(target)) names.add(key);
    for (const key of Object.getOwnPropertyNames(target)) names.add(key);
    console.log(Array.from(names).filter(n => n !== 'default').sort().join(' '));
    """
}

func realNames(_ module: String) -> Set<String> {
    let dir = base.appendingPathComponent("real-\(module.replacingOccurrences(of: "/", with: "-"))")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try? script(for: module).write(to: dir.appendingPathComponent("main.js"), atomically: true, encoding: .utf8)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: realNode)
    process.arguments = ["main.js"]
    process.currentDirectoryURL = dir
    let out = Pipe()
    process.standardOutput = out
    process.standardError = Pipe()
    try? process.run()
    process.waitUntilExit()
    let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    return Set(text.split(separator: " ").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
}

func ourNames(_ module: String) async -> Set<String> {
    let dir = base.appendingPathComponent("ours-\(module.replacingOccurrences(of: "/", with: "-"))")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let engine = NodeEngine(root: dir, env: ["PATH": "/"])
    let result = await engine.run(source: script(for: module), path: "/main.js",
                                  argv: ["node", "/main.js"], cwd: "/", stdin: "")
    if !result.err.isEmpty { print("  (\(module) stderr: \(result.err.trimmingCharacters(in: .whitespacesAndNewlines)))") }
    return Set(result.out.split(separator: " ").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
}

// Promoted from investigation to GATE: the findings are settled, so what is absent is now a
// CLAIM rather than a note. Everything still missing is one of two things — a refusal with a
// measured reason, or a node INTERNAL this engine deliberately does not carry. Anything else
// appearing here is either a regression or a new node API worth adding, and either way the
// suite should say so rather than printing a number nobody reads.
//
// A name is expected-absent if it starts with "_" (node internals) or is listed below.
let expectedAbsent: Set<String> = [
    // Measured refusals, each with its reason recorded in system.md.
    "subtle",                                    // crypto.subtle: deliberate, for feature detection
    "transferableAbortController", "transferableAbortSignal",  // need transfer semantics
    "setTraceSigInt",                            // node's SIGINT tracing hook
    "binding", "domain",                         // process.binding is internal; domain is set by the module
]
// zstd is absent wholesale and measured: the system compression framework has no zstd.
func isZstd(_ name: String) -> Bool { name.hasPrefix("ZSTD_") || name.hasPrefix("Zstd") }

var totalMissing = 0
var unexplained: [String] = []
for module in modules {
    let real = realNames(module)
    let ours = await ourNames(module)
    let missing = real.subtracting(ours).sorted()
    let extra = ours.subtracting(real).sorted()
    totalMissing += missing.count
    print("\(module): \(ours.intersection(real).count)/\(real.count) present")
    if !missing.isEmpty { print("  MISSING: \(missing.joined(separator: " "))") }
    if !extra.isEmpty { print("  ours only: \(extra.joined(separator: " "))") }
    for name in missing where !name.hasPrefix("_") && !isZstd(name) && !expectedAbsent.contains(name) {
        unexplained.append("\(module).\(name)")
    }
}
print("total missing across modules: \(totalMissing)")
if unexplained.isEmpty {
    print("SURFACE MATCH — every absence is a recorded refusal or a node internal")
} else {
    print("SURFACE MISMATCH — \(unexplained.count) absent with no recorded reason:")
    for name in unexplained.prefix(20) { print("  \(name)") }
    exit(1)
}
try? FileManager.default.removeItem(at: base)
