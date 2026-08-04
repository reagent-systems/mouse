import Foundation
setvbuf(stdout, nil, _IONBF, 0)

// 1824 pattern x path cases against real node. The refusal said a partial matcher would be worse
// than none — a fair judgement about risk, not a claim of impossibility. This is how the repo
// settles that kind of question elsewhere: msh against /bin/sh, the screen against pyte.
let here = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let source = (try? String(contentsOf: here.appendingPathComponent("corpus.js"), encoding: .utf8)) ?? ""
let expected = (try? String(contentsOf: here.appendingPathComponent("node.txt"), encoding: .utf8)) ?? ""

let engine = NodeEngine(root: here, env: ["PATH": "/usr/bin"])
let mine = await engine.run(source: source, path: "/corpus.js",
                            argv: ["node", "/corpus.js"], cwd: "/", stdin: "")
if !mine.err.isEmpty { print("stderr: \(mine.err.prefix(600))") }

func rows(_ text: String) -> [String: String] {
    var out: [String: String] = [:]
    for line in text.split(separator: "\n") {
        let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3 else { continue }
        out[parts[0] + "\u{1}" + parts[1]] = parts[2]
    }
    return out
}
let a = rows(expected), b = rows(mine.out)
print("node cases: \(a.count)  ours: \(b.count)")

var mismatches: [String] = []
for (key, value) in a.sorted(by: { $0.key < $1.key }) {
    let ours = b[key] ?? "<missing>"
    if ours != value {
        let parts = key.split(separator: "\u{1}", omittingEmptySubsequences: false).map(String.init)
        mismatches.append("  pattern=\(parts[0].debugDescription) path=\(parts[1].debugDescription) node=\(value) ours=\(ours)")
    }
}
if mismatches.isEmpty {
    print("GLOB MATCH — all \(a.count) cases identical to real node")
} else {
    print("GLOB MISMATCH — \(mismatches.count) of \(a.count) differ")
    for line in mismatches.prefix(40) { print(line) }
    exit(1)
}
