import Foundation
setvbuf(stdout, nil, _IONBF, 0)

// The heaviest real-package proof here: jest runs every test file inside its own `vm` context,
// keeps a private module registry on node's internals, and drives its own reporters. It was
// blocked until vm contexts became real — a second JSContext in the engine's virtual machine.
// Only the structured results are compared; jest's reporter carries timings and paths.
func results(_ text: String) -> [String] {
    text.split(separator: "\n").map(String.init).filter {
        $0.hasPrefix("cold ") || $0.hasPrefix("warm ") || $0.hasPrefix("THREW ")
    }
}
let here = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let source = (try? String(contentsOf: here.appendingPathComponent("run.js"), encoding: .utf8)) ?? ""
let expected = results((try? String(contentsOf: here.appendingPathComponent("node.txt"), encoding: .utf8)) ?? "")
// The cache must be cold at the start, or the gate is not testing what it claims.
try? FileManager.default.removeItem(at: here.appendingPathComponent("tmp"))

// The packages this harness needs are installed HERE, on first run, by the engine's own package
// manager — `node_modules` is not checked in, and a harness that assumes a tree someone else
// left behind is a harness that passes for the wrong reason. It is skipped when already present
// so a re-run costs nothing.
let packagesRoot = here.appendingPathComponent("project")
if !FileManager.default.fileExists(atPath: packagesRoot.appendingPathComponent("node_modules").path) {
    print("installing jest dependencies with our own package manager…")
    do { _ = try await PackageManager.install(requirements: ["jest": "^29.7.0"], into: packagesRoot) }
    catch { print("JEST FAILED — install: \(error)"); exit(1) }
}

let engine = NodeEngine(root: here, env: ["PATH": "/usr/bin", "NODE_ENV": "test"])
let started = Date()
let mine = await engine.run(source: source, path: "/run.js", argv: ["node", "/run.js"], cwd: "/", stdin: "")
let elapsed = Date().timeIntervalSince(started)
let ours = results(mine.out)
var bad = 0
for i in 0..<max(expected.count, ours.count) {
    let want = i < expected.count ? expected[i] : "<missing>"
    let got = i < ours.count ? ours[i] : "<missing>"
    if want != got { print("  node: \(want)\n  ours: \(got)"); bad += 1 }
}
if bad == 0 && !ours.isEmpty {
    print("JEST MATCH — \(expected.count) results identical across a COLD and a WARM (cached) run, in vm contexts (\(String(format: "%.1f", elapsed))s)")
    for line in expected { print("  \(line)") }
} else {
    print("JEST DIFFERS — \(bad) lines")
    if !mine.err.isEmpty { print("stderr: \(mine.err.prefix(700))") }
    exit(1)
}
