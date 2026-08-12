import Foundation
setvbuf(stdout, nil, _IONBF, 0)

// Leaving a project must take its running program with it.
//
// Tapping the project's name in the Files container goes back to the picker, and the ring drops
// the terminal session it had memoized on that workspace. Dropping it without stopping it strands
// whatever was running: a dev server keeps its port, keeps serving, and nothing on screen can
// reach it any more — the "a running program could not be stopped at all" trap in a new costume,
// with killing the app as the only way out.
//
// Asking politely is not enough and that is the point of testing it here rather than trusting it.
// A ^C is a KEYSTROKE, and a program decides what to do with one; vite reads it and keeps serving.
// So `stopForProjectChange` uses the close-button path, and this drives the same TerminalSession
// the app owns to prove the port actually goes away.
@MainActor func run() async {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("leaveproject-\(getpid())")
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }

    let port = 5391
    let server = """
    const http = require('http');
    http.createServer((req, res) => res.end('still here')).listen(\(port), () => {
      console.log('listening on \(port)');
    });
    """
    try? server.write(to: base.appendingPathComponent("server.js"), atomically: true, encoding: .utf8)

    func answers() async -> Bool {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/")!)
        request.timeoutInterval = 2
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return false }
        return String(decoding: data, as: UTF8.self) == "still here"
    }
    func waitUntil(_ wanted: Bool, seconds: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await answers() == wanted { return true }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return await answers() == wanted
    }

    let session = TerminalSession(root: base)
    _ = session.run("node server.js")

    var failures = 0
    func check(_ condition: Bool, _ label: String) {
        if condition { print("  ok: \(label)") } else { failures += 1; print("  FAIL: \(label)") }
    }

    // A gate that only proves the port is closed would pass against a server that never started.
    check(await waitUntil(true, seconds: 60), "the server answered while the project was open")
    // The full-screen launch path is the one the app uses for `npm run dev`, and the one whose
    // program a project change has to stop.
    check(session.program != nil, "the program owns the terminal — the path npm run dev takes")

    session.stopForProjectChange()

    check(await waitUntil(false, seconds: 20), "the port stops answering once the project is left")
    let cleared = Date().addingTimeInterval(5)
    while session.program != nil && Date() < cleared {
        try? await Task.sleep(nanoseconds: 100_000_000)
    }
    check(session.program == nil, "the screen is reclaimed — no program left installed")
    check(!session.isRunning, "the session is idle afterwards")

    if failures == 0 {
        print("LEAVE PROJECT: 5 checks — a project change stops what the project was running, "
              + "and its port goes with it — MATCH")
    } else {
        print("LEAVE PROJECT: \(failures) of 5 checks failed — MISMATCH")
        exit(1)
    }
}
await run()
