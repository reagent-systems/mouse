import Foundation
setvbuf(stdout, nil, _IONBF, 0)

// pathToFileURL / fileURLToPath were stubs. A path is not a URL, so this is a vector table:
// every path whose encoding differs from its literal text, each one round-tripped, plus the
// searchParams cache-bust eslint actually performs and the two rejections node makes.
let here = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let source = (try? String(contentsOf: here.appendingPathComponent("probe.js"), encoding: .utf8)) ?? ""
let expected = ((try? String(contentsOf: here.appendingPathComponent("node.txt"), encoding: .utf8)) ?? "")
    .trimmingCharacters(in: .whitespacesAndNewlines)

let engine = NodeEngine(root: here, env: [:])
let mine = await engine.run(source: source, path: "/probe.js",
                            argv: ["node", "/probe.js"], cwd: "/", stdin: "")
let ours = mine.out.trimmingCharacters(in: .whitespacesAndNewlines)

let a = expected.split(separator: "\n").map(String.init)
let b = ours.split(separator: "\n").map(String.init)
var bad = 0
for i in 0..<max(a.count, b.count) {
    let want = i < a.count ? a[i] : "<missing>"
    let got = i < b.count ? b[i] : "<missing>"
    if want != got { print("  node: \(want)\n  ours: \(got)"); bad += 1 }
}
if bad == 0 && !ours.isEmpty {
    print("FILE URL MATCH — \(a.count) vectors byte-identical to node")
} else {
    print("FILE URL FAILED — \(bad) lines differ")
    if !mine.err.isEmpty { print("stderr: \(mine.err.prefix(600))") }
    exit(1)
}
