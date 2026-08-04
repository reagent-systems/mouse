import Foundation
setvbuf(stdout, nil, _IONBF, 0)

// A gate on the DOCUMENTATION. Four times this session the record was wrong rather than the code —
// a caveat reasoned instead of measured, a fixture asserting a capability was still missing, a
// miscount of absent globals, a gap list naming something already built. Docs rot silently
// because nothing fails when they do; this makes something fail.
//
// The expected set below is what system.md and the README currently claim is absent. If one of
// these starts WORKING, the docs are stale and this fails until they are corrected.
let stillAbsent: Set<String> = [
    "crypto.subtle", "path.matchesGlob", 
    "zlib.zstdCompressSync", "https.createServer",
    "crypto keyType dsa", "SharedArrayBuffer across workers",
]
let here = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let source = (try? String(contentsOf: here.appendingPathComponent("script.js"), encoding: .utf8)) ?? ""
let engine = NodeEngine(root: here, env: ["PATH": "/usr/bin"])
let mine = await engine.run(source: source, path: "/script.js",
                            argv: ["node", "/script.js"], cwd: "/", stdin: "")
if !mine.err.isEmpty { print("stderr: \(mine.err.prefix(300))") }

var stale: [String] = []
var regressed: [String] = []
for line in mine.out.split(separator: "\n") {
    let parts = line.components(separatedBy: ": ")
    guard parts.count == 2 else { continue }
    let (name, verdict) = (parts[0], parts[1])
    print("  \(verdict == "WORKS" ? "works " : "absent") \(name)")
    if stillAbsent.contains(name), verdict == "WORKS" { stale.append(name) }
    if !stillAbsent.contains(name), verdict != "WORKS" { regressed.append(name) }
}
if !stale.isEmpty { print("\nDOCS STALE — these are documented as absent but WORK: \(stale.joined(separator: ", "))") }
if !regressed.isEmpty { print("\nREGRESSED — documented as working but absent: \(regressed.joined(separator: ", "))") }
if stale.isEmpty && regressed.isEmpty { print("\nDOC CLAIMS MATCH — every documented gap is still a gap, every built thing still works") }
exit(stale.isEmpty && regressed.isEmpty ? 0 : 1)
