import Foundation
setvbuf(stdout, nil, _IONBF, 0)

// A real-package proof, which is different evidence from a surface sweep: eslint through its Node
// API exercises config loading (ESM config from a CommonJS entry), a recursive walk of src/**,
// module resolution across ~14 MB of dependencies, and then the rules themselves. It leans on
// several things built this session — fs.glob, recursive readdir, the stricter fs errors — in
// combination rather than one at a time.
let here = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let source = (try? String(contentsOf: here.appendingPathComponent("run.js"), encoding: .utf8)) ?? ""
let expected = ((try? String(contentsOf: here.appendingPathComponent("node.txt"), encoding: .utf8)) ?? "")
    .trimmingCharacters(in: .whitespacesAndNewlines)
    // node prints absolute paths only in the filePath; the script already reduces to basenames.

let engine = NodeEngine(root: here, env: ["PATH": "/usr/bin"])
let started = Date()
let mine = await engine.run(source: source, path: "/run.js",
                            argv: ["node", "/run.js"], cwd: "/", stdin: "")
let elapsed = Date().timeIntervalSince(started)
let ours = mine.out.trimmingCharacters(in: .whitespacesAndNewlines)

if ours == expected, !ours.isEmpty {
    print("ESLINT MATCH — same findings on the same files (\(String(format: "%.1f", elapsed))s)")
    print(ours)
} else {
    print("ESLINT DIFFERS")
    let a = expected.split(separator: "\n").map(String.init)
    let b = ours.split(separator: "\n").map(String.init)
    for i in 0..<max(a.count, b.count) {
        let x = i < a.count ? a[i] : "<missing>"
        let y = i < b.count ? b[i] : "<missing>"
        print(x == y ? "  = \(x)" : "  node: \(x)\n  ours: \(y)")
    }
    if !mine.err.isEmpty { print("stderr: \(mine.err.prefix(900))") }
    exit(1)
}
