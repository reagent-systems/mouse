import Foundation
setvbuf(stdout, nil, _IONBF, 0)

// What a program sees in process.argv, which npm scripts depend on constantly: `node -e "…" x`
// has NO script path — argv[1] is the first extra argument — while `node file.js x` does. A
// phantom path in the eval form made every `node -e` script read the wrong argument, and npm
// scripts are full of them.

let realNode = "/Users/thyfriendlyfox/.local/bin/node"
let base = FileManager.default.temporaryDirectory.appendingPathComponent("evalargv-\(getpid())")
try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
let code = "console.log(JSON.stringify(process.argv.slice(1)))"
try? "\(code)\n".write(to: base.appendingPathComponent("show.js"), atomically: true, encoding: .utf8)

func real(_ arguments: [String]) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: realNode)
    process.arguments = arguments
    process.currentDirectoryURL = base
    let out = Pipe()
    process.standardOutput = out
    process.standardError = Pipe()
    try? process.run()
    let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
}

@MainActor func msh(_ line: String) async -> String {
    let shell = MouseShell()
    let outputs = await shell.runProgram(line, context: MouseShell.Context(root: base), interactive: false)
    return outputs.map(\.text).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
}

var failures = 0
let cases: [(String, [String], String)] = [
    ("node -e, no arguments", ["-e", code], "node -e '\(code)'"),
    ("node -e with arguments", ["-e", code, "one", "two"], "node -e '\(code)' one two"),
    ("node file.js with arguments", ["show.js", "one", "two"], "node show.js one two"),
]
for (label, arguments, line) in cases {
    // The file form carries an absolute path on one side and a workspace path on the other;
    // the CLAIM is which entries are there, so the path itself is normalised away.
    func shape(_ text: String) -> String {
        guard let range = text.range(of: "\"[^\"]*show\\.js\"", options: .regularExpression) else { return text }
        return text.replacingCharacters(in: range, with: "\"SCRIPT\"")
    }
    let theirs = shape(real(arguments)), mine = shape(await msh(line))
    if mine == theirs {
        print("ok: \(label) -> \(mine)")
    } else {
        failures += 1
        print("MISMATCH: \(label)\n  ours: \(mine)\n  node: \(theirs)")
    }
}
if failures == 0 {
    print("ARGV MATCH — `node -e` argv has no script path and `node file.js` does, as node's do")
} else {
    print("FAIL: \(failures) of \(cases.count) differ")
    exit(1)
}
try? FileManager.default.removeItem(at: base)
