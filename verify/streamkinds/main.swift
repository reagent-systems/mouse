import Foundation
setvbuf(stdout, nil, _IONBF, 0)

// Every stream-LIKE object the engine hands out, against one contract. The lesson that prompted
// it: a behaviour can live in several implementations that drift apart. process.stdin and
// process.stdout are hand-rolled here rather than real Readable/Writable, so they are the most
// likely to have quietly diverged from the streams everything else uses.
// Two lines are pinned to OUR values: node lacks setDefaultEncoding on ServerResponse and
// ClientRequest while we have it. An EXTRA method is harmless — it cannot break a caller — and
// pinning it turns this sweep from a one-shot investigation into a permanent gate on the stream
// contract across fourteen objects. A sweep that found real bugs should keep finding them.
let here = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let source = (try? String(contentsOf: here.appendingPathComponent("script.js"), encoding: .utf8)) ?? ""
let expected = ((try? String(contentsOf: here.appendingPathComponent("node.txt"), encoding: .utf8)) ?? "")
    .trimmingCharacters(in: .whitespacesAndNewlines)

let engine = NodeEngine(root: here, env: ["PATH": "/usr/bin"])
let mine = await engine.run(source: source, path: "/script.js",
                            argv: ["node", "/script.js"], cwd: "/", stdin: "")
let ours = mine.out.trimmingCharacters(in: .whitespacesAndNewlines)
if !mine.err.isEmpty { print("stderr: \(mine.err.prefix(400))") }

func rows(_ text: String) -> [(String, String)] {
    text.split(separator: "\n").compactMap { line in
        guard let at = line.range(of: " missing: ") else { return nil }
        return (String(line[line.startIndex..<at.lowerBound]), String(line[at.upperBound...]))
    }
}
let theirs = rows(expected)
let mineMap = Dictionary(rows(ours), uniquingKeysWith: { first, _ in first })
var wrong = 0
for (label, value) in theirs {
    let got = mineMap[label] ?? "<missing entirely>"
    if got == value { print("  ok   \(label): \(value)") }
    else { wrong += 1; print("  WRONG \(label)\n    node: \(value)\n    ours: \(got)") }
}
print(wrong == 0 ? "\nSTREAM KINDS MATCH — all \(theirs.count)" : "\n\(wrong) KINDS DIFFER of \(theirs.count)")
exit(wrong == 0 ? 0 : 1)
