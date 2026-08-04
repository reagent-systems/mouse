import Foundation
setvbuf(stdout, nil, _IONBF, 0)

// `npm install` on the phone printed NOTHING — the packages landed, the tree refreshed, and the
// prompt came back with no word about what happened. On a slow connection that is
// indistinguishable from a hang, and it is the only feedback a person gets for the longest
// operation the terminal performs. This asks the shell directly what it returns.
@MainActor func run() async {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("npmsays-\(getpid())")
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }

    let shell = MouseShell()
    let context = MouseShell.Context(root: base)
    let outputs = await shell.runProgram("npm install left-pad", context: context, interactive: false)
    let text = outputs.map(\.text).joined(separator: "\n")
    print("non-interactive: [\(text)]")

    // The app runs every command INTERACTIVELY. If that path answers differently, the phone sees
    // something the harnesses never do — which is exactly what happened.
    let base2 = FileManager.default.temporaryDirectory.appendingPathComponent("npmsays2-\(getpid())")
    try? FileManager.default.createDirectory(at: base2, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base2) }
    let shell2 = MouseShell()
    // Exactly what the app builds: an `emit` sink attached, which switches a SOLO command from
    // collecting its output to streaming it. That is the difference between the harness and the
    // phone, and it is why every harness said this worked.
    var streamed: [String] = []
    var context2 = MouseShell.Context(root: base2)
    context2.emit = { streamed.append($0.text) }
    let interactiveOutputs = await shell2.runProgram("npm install left-pad",
                                                     context: context2, interactive: true)
    let interactiveText = interactiveOutputs.map(\.text).joined(separator: "\n")
    print("with emit sink — returned: [\(interactiveText)] streamed: \(streamed)")

    print("status: \(shell.lastStatus)")
    print("output: [\(text)]")
    let installed = FileManager.default.fileExists(atPath:
        base.appendingPathComponent("node_modules/left-pad/package.json").path)
    print("installed on disk: \(installed)")

    var problems: [String] = []
    if !installed { problems.append("left-pad never installed") }
    if !text.contains("added") { problems.append("the shell said nothing about adding packages") }
    if problems.isEmpty {
        print("NPM SAYS MATCH — an install reports what it did")
    } else {
        for problem in problems { print("  \(problem)") }
        print("NPM SAYS MISMATCH")
        exit(1)
    }
}
await run()
