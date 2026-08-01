import Foundation
setvbuf(stdout, nil, _IONBF, 0)

// The shell provably returns "added N packages" (scratchpad/term/npmsays), and the phone shows
// nothing. This drives the TERMINAL SESSION — the same object the app owns, the same run() the
// prompt calls — so the answer is either "the session never got the line" (a session bug) or
// "the session has it" (a rendering bug). Guessing between those two cost an iteration.
@MainActor func run() async {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("termsays-\(getpid())")
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }

    let session = TerminalSession(root: base)
    _ = session.run("npm install left-pad")

    // The command is asynchronous; wait for the session to say it finished.
    let deadline = Date().addingTimeInterval(120)
    while session.isRunning && Date() < deadline {
        await Task.yield()
        try? await Task.sleep(nanoseconds: 20_000_000)
    }

    print("isRunning after: \(session.isRunning)")
    for line in session.lines { print("  line[\(line.kind)]: \(line.text)") }

    let installed = FileManager.default.fileExists(atPath:
        base.appendingPathComponent("node_modules/left-pad/package.json").path)
    print("installed on disk: \(installed)")

    var problems: [String] = []
    if !installed { problems.append("left-pad never installed") }
    if !session.lines.contains(where: { $0.text.contains("added") }) {
        problems.append("the session's scrollback never got the 'added N packages' line")
    }
    if problems.isEmpty {
        print("TERMINAL SAYS MATCH — an install reports what it did, in the session's own scrollback")
    } else {
        for problem in problems { print("  \(problem)") }
        print("TERMINAL SAYS MISMATCH")
        exit(1)
    }
}
await run()
