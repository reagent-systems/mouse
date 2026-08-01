import Foundation
setvbuf(stdout, nil, _IONBF, 0)

// mocha is a different SHAPE of real-package proof from eslint: a test runner lives on the
// parts of the runtime that are hardest to fake — async failure, promise rejection inside a
// user callback, timers racing a timeout, `done()` callbacks, and an exit code that has to
// reflect the result. Durations and stack paths vary, so only the structured result lines and
// the exit code are compared.
func results(_ text: String) -> [String] {
    text.split(separator: "\n").map(String.init).filter { line in
        line.hasPrefix("pass ") || line.hasPrefix("fail ") || line.hasPrefix("pending ")
            || line.hasPrefix("failures:") || line.hasPrefix("exit=")
    }
}

let here = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let source = (try? String(contentsOf: here.appendingPathComponent("run.js"), encoding: .utf8)) ?? ""
let expected = results((try? String(contentsOf: here.appendingPathComponent("node.txt"), encoding: .utf8)) ?? "")

let engine = NodeEngine(root: here, env: ["PATH": "/usr/bin"])
let mine = await engine.run(source: source, path: "/run.js",
                            argv: ["node", "/run.js"], cwd: "/", stdin: "")
var ours = results(mine.out)
ours.append("exit=\(mine.status)")

var bad = 0
for i in 0..<max(expected.count, ours.count) {
    let want = i < expected.count ? expected[i] : "<missing>"
    let got = i < ours.count ? ours[i] : "<missing>"
    if want != got { print("  node: \(want)\n  ours: \(got)"); bad += 1 }
}
if bad == 0 && !ours.isEmpty {
    print("MOCHA MATCH — \(expected.count) results identical, including the exit code")
    for line in expected { print("  \(line)") }
} else {
    print("MOCHA FAILED — \(bad) lines differ")
    if !mine.err.isEmpty { print("stderr: \(mine.err.prefix(1200))") }
    exit(1)
}
