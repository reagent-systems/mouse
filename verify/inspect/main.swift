import Foundation
setvbuf(stdout, nil, _IONBF, 0)

// The FORMATTING audit. For a terminal IDE this is not cosmetic: console.log output IS what the
// user reads, and it is what gets pasted into a bug report. node's inspect has specific shapes
// for Map, Set, Date, class instances, circular references, sparse arrays, getters and long
// collections, and a homegrown formatter drifts from all of them quietly.
let here = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let source = (try? String(contentsOf: here.appendingPathComponent("script.js"), encoding: .utf8)) ?? ""
let expected = ((try? String(contentsOf: here.appendingPathComponent("node.txt"), encoding: .utf8)) ?? "")
    .trimmingCharacters(in: .whitespacesAndNewlines)

let engine = NodeEngine(root: here, env: ["PATH": "/usr/bin"])
let mine = await engine.run(source: source, path: "/script.js",
                            argv: ["node", "/script.js"], cwd: "/", stdin: "")
let ours = mine.out.trimmingCharacters(in: .whitespacesAndNewlines)
if !mine.err.isEmpty { print("stderr: \(mine.err.prefix(400))") }

// Keyed by LABEL, not line index. A line-index diff misreported every case after the one
// multi-line divergence, which made a dozen identical lines look broken — a harness flaw that
// would have sent me chasing bugs that were not there.
func byLabel(_ text: String) -> [(String, String)] {
    var out: [(String, String)] = []
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let piece = String(line)
        if let colon = piece.range(of: ": "), !piece.hasPrefix(" ") {
            out.append((String(piece[piece.startIndex..<colon.lowerBound]),
                        String(piece[colon.upperBound...])))
        } else if var last = out.popLast() {
            last.1 += "\n" + piece            // a continuation of the previous entry
            out.append(last)
        }
    }
    return out
}
let theirs = byLabel(expected), mineRows = byLabel(ours)
let mineMap = Dictionary(mineRows, uniquingKeysWith: { first, _ in first })
var wrong = 0
let a = theirs.map { $0.0 }
for (label, value) in theirs {
    let got = mineMap[label] ?? "<missing>"
    if got == value { print("  ok   \(label)") }
    else { wrong += 1; print("  WRONG \(label)\n    node: \(value.prefix(90))\n    ours: \(got.prefix(90))") }
}
print(wrong == 0 ? "\nFORMATTING MATCHES — all \(a.count)" : "\n\(wrong) FORMATS DIFFER of \(a.count)")
