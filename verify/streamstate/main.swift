import Foundation
setvbuf(stdout, nil, _IONBF, 0)

// Stream STATE values across a lifecycle. The shape sweep proves a property EXISTS; it cannot see
// one reporting the wrong value. Two in-flight bugs — highWaterMark, then writableLength — came
// from state going stale when a value moved between places, so this reads the values at each
// point a program would actually consult them.
let here = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let source = (try? String(contentsOf: here.appendingPathComponent("script.js"), encoding: .utf8)) ?? ""
let expected = ((try? String(contentsOf: here.appendingPathComponent("node.txt"), encoding: .utf8)) ?? "")
    .trimmingCharacters(in: .whitespacesAndNewlines)

let engine = NodeEngine(root: here, env: ["PATH": "/usr/bin"])
let mine = await engine.run(source: source, path: "/script.js",
                            argv: ["node", "/script.js"], cwd: "/", stdin: "")
let ours = mine.out.trimmingCharacters(in: .whitespacesAndNewlines)
if !mine.err.isEmpty { print("stderr: \(mine.err.prefix(400))") }

// Keyed by label — a line-index diff misreports everything after the first divergence.
func rows(_ text: String) -> [(String, String)] {
    text.split(separator: "\n").compactMap { line in
        guard let colon = line.range(of: ": ") else { return nil }
        return (String(line[line.startIndex..<colon.lowerBound]), String(line[colon.upperBound...]))
    }
}
let theirs = rows(expected)
let mineMap = Dictionary(rows(ours), uniquingKeysWith: { first, _ in first })
var wrong = 0
for (label, value) in theirs {
    let got = mineMap[label] ?? "<missing>"
    if got == value { print("  ok   \(label): \(value)") }
    else { wrong += 1; print("  WRONG \(label)\n    node: \(value)\n    ours: \(got)") }
}
print(wrong == 0 ? "\nSTREAM STATE MATCHES — all \(theirs.count)" : "\n\(wrong) STATE VALUES DIFFER of \(theirs.count)")
