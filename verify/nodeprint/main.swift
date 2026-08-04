import Foundation
setvbuf(stdout, nil, _IONBF, 0)

// `node -p` — `-e` that prints the expression's value. It was unimplemented, so it fell through
// to the file path and answered "node: can't read -p", which reads as a missing FILE rather than
// a missing flag. n8n's bin found it on the phone. Every case runs through real node and through
// msh's `node`, and the two texts must match.
let realNode = "/Users/thyfriendlyfox/.local/bin/node"

// Values, not just types: a string prints unquoted (console.log, not inspect), an object prints
// inspected, undefined prints, and a require inside the expression must still resolve.
let cases: [[String]] = [
    ["-p", "1 + 1"],
    ["-p", "'hi'"],
    ["-p", "({a: 1})"],
    ["-p", "[1, 2, 3]"],
    ["-p", "undefined"],
    ["-p", "null"],
    ["-p", "typeof require"],
    ["-p", "require('path').join('a', 'b')"],
    ["-p", "JSON.stringify({nested: {deep: true}})"],
    ["-p", "'quote\" and \\\\backslash'"],
    ["-p", "[...Array(3).keys()].join(',')"],
    ["--print", "2 * 21"],
    // -e must keep printing nothing on its own.
    ["-e", "1 + 1"],
    ["-e", "console.log('explicit')"],
]

@MainActor func run() async {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("nodeprint-\(getpid())")
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }

    var differences: [String] = []
    for argv in cases {
        let node = Process()
        node.executableURL = URL(fileURLWithPath: realNode)
        node.arguments = argv
        let out = Pipe(), err = Pipe()
        node.standardOutput = out
        node.standardError = err
        try? node.run()
        let theirs = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        _ = err.fileHandleForReading.readDataToEndOfFile()
        node.waitUntilExit()

        let shell = MouseShell()
        let context = MouseShell.Context(root: base)
        let command = "node " + argv.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
        let outputs = await shell.runProgram(command, context: context, interactive: false)
        let mine = outputs.map(\.text).joined(separator: "\n")

        let want = theirs.trimmingCharacters(in: .newlines)
        let got = mine.trimmingCharacters(in: .newlines)
        if want != got {
            differences.append("  \(argv.joined(separator: " "))\n    node: [\(want)]\n    ours: [\(got)]")
        }
    }

    if differences.isEmpty {
        print("NODE PRINT MATCH — all \(cases.count) forms identical to real node: -p and --print "
              + "printing a value the way console.log does (a string unquoted, an object "
              + "inspected, undefined as undefined), require resolving inside the expression, "
              + "quoting surviving, and -e still printing nothing of its own")
    } else {
        for difference in differences { print(difference) }
        print("NODE PRINT MISMATCH — \(differences.count) of \(cases.count) differ")
        exit(1)
    }
}
await run()
