import Foundation
setvbuf(stdout, nil, _IONBF, 0)

// The CONSOLE audit. In a terminal IDE every one of these is a visible feature, and the ROUTING
// matters as much as the text: warn/error belong on stderr, so a tool piping stdout does not get
// them mixed into its data. Both streams are compared.
let here = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let source = (try? String(contentsOf: here.appendingPathComponent("script.js"), encoding: .utf8)) ?? ""
func load(_ name: String) -> String {
    ((try? String(contentsOf: here.appendingPathComponent(name), encoding: .utf8)) ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
}
let expectedOut = load("node-out.txt"), expectedErr = load("node-err.txt")

let engine = NodeEngine(root: here, env: ["PATH": "/usr/bin"])
let mine = await engine.run(source: source, path: "/script.js",
                            argv: ["node", "/script.js"], cwd: "/", stdin: "")
// The timer duration is real elapsed time; only its shape can be compared.
func normalise(_ text: String) -> [String] {
    text.trimmingCharacters(in: .whitespacesAndNewlines)
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map { $0.hasPrefix("t: ") ? "t: <duration>" : String($0) }
}
var wrong = 0
for (label, expected, got) in [("stdout", expectedOut, mine.out), ("stderr", expectedErr, mine.err)] {
    let a = normalise(expected), b = normalise(got)
    print("--- \(label) ---")
    for i in 0..<max(a.count, b.count) {
        let x = i < a.count ? a[i] : "<missing>"
        let y = i < b.count ? b[i] : "<missing>"
        if x == y { print("  ok   \(x)") } else { wrong += 1; print("  WRONG node: \(x)\n        ours: \(y)") }
    }
}
print(wrong == 0 ? "\nCONSOLE MATCHES" : "\n\(wrong) CONSOLE LINES DIFFER")
