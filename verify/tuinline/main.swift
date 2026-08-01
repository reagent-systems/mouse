import Foundation
setvbuf(stdout, nil, _IONBF, 0)

// The inline-repaint half of the engagement rule, through the REAL TerminalSession — the same
// object the app's terminal owns, the same run() the prompt calls.
//
// The diagnosis this gate came from (2026-08-01): an ink-style TUI that never touches the alt
// screen repainted by cursor-up landed every frame in the SCROLLBACK — stacking, cursor motion
// meaningless — because engagement was keyed only on alt-screen and raw mode, and a program
// that repaints before (or without) either got neither the grid nor a visible response to a
// keystroke. The rule now also engages on upward cursor motion (TerminalPrograms.swift), the
// session exposes the flip observably (`programOnScreen`), and the grid is shadow-fed in
// transcript mode so the first engaged frame repaints rows that are actually there.
@MainActor
func pump(until ready: () -> Bool, seconds: Double = 30) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if ready() { return true }
        await Task.yield()
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return ready()
}

@MainActor
func gridRow(_ session: TerminalSession, _ row: Int) -> String { session.screen.text(row: row) }

@MainActor
func makeSession(script: String?, name: String) -> (TerminalSession, URL) {
    // Fixtures are created HERE, on every run — nothing is assumed left behind.
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("tuinline-\(name)-\(getpid())")
    try? FileManager.default.removeItem(at: base)
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    if let script {
        try? script.write(to: base.appendingPathComponent("tui.js"), atomically: true, encoding: .utf8)
    }
    let session = TerminalSession(root: base)
    session.setGridSize(rows: 10, columns: 48)
    return (session, base)
}

@MainActor func main() async {
    var failures = 0
    func expect(_ condition: Bool, _ label: String) {
        if !condition { print("  \(label)"); failures += 1 }
    }

    // -- Case 1: ink's core move. Draw three lines, then repaint by cursor-up + erase-down +
    // rewrite. NO alternate screen, NO raw mode — nothing but the repaint itself says "TUI".
    let inline = """
    process.stdout.write('ALPHA\\nBETA original\\nGAMMA\\n');
    const repaint = (middle) => {
      process.stdout.write('\\u001b[3A\\u001b[J');
      process.stdout.write('ALPHA\\n' + middle + '\\nGAMMA\\n');
    };
    setTimeout(() => repaint('BETA repaint one'), 150);
    setTimeout(() => repaint('BETA repaint two'), 300);
    process.stdin.on('data', (key) => {
      const k = String(key);
      if (k === 'q') process.exit(0);
      else repaint('KEY:' + k);
    });
    """
    let (session, base) = makeSession(script: inline, name: "inline")
    defer { try? FileManager.default.removeItem(at: base) }
    _ = session.run("node tui.js")

    let engaged = await pump(until: { session.programOnScreen })
    expect(engaged, "the grid never engaged for an inline-repaint program")
    guard engaged else { print("TUI INLINE FAILED — \(failures)"); exit(1) }
    expect(session.program != nil, "programOnScreen without a program")

    // The repaint replaces the SAME rows. Two frames deep so a stack would already show.
    let repainted = await pump(until: { gridRow(session, 1) == "BETA repaint two" })
    expect(repainted, "second repaint never reached grid row 1 (row 1: |\(gridRow(session, 1))|)")
    expect(gridRow(session, 0) == "ALPHA", "row 0 should still be ALPHA, got |\(gridRow(session, 0))|")
    expect(gridRow(session, 2) == "GAMMA", "row 2 should still be GAMMA, got |\(gridRow(session, 2))|")
    // No frame stacking: total row usage did not grow — everything below the frame is blank.
    for row in 3..<session.screen.rows {
        expect(gridRow(session, row).isEmpty, "frame stacked into grid row \(row): |\(gridRow(session, row))|")
    }
    // No stacking in the scrollback either: repaints happen on the grid, not as appended lines.
    let linesBeforeKey = session.lines.count

    // A keystroke mid-run reaches the program: it echoes the marker into its frame.
    expect(session.sendKey("x"), "sendKey refused while a program is running")
    let echoed = await pump(until: { gridRow(session, 1) == "KEY:x" })
    expect(echoed, "the keystroke never reached the program (row 1: |\(gridRow(session, 1))|)")
    expect(session.lines.count == linesBeforeKey,
           "repaints leaked into the scrollback (\(linesBeforeKey) → \(session.lines.count) lines)")

    // Exit: back to the scrollback, prompt usable, and the TUI's last frame kept in history —
    // what a real terminal shows after an inline TUI ends.
    _ = session.sendKey("q")
    let ended = await pump(until: { session.program == nil })
    expect(ended, "the program did not exit on q")
    expect(!session.programOnScreen, "programOnScreen stuck after exit")
    let tail = session.lines.suffix(3).map(\.text)
    expect(tail == ["ALPHA", "KEY:x", "GAMMA"],
           "final frame not preserved in the scrollback, tail: \(tail)")
    expect(session.run("echo after"), "the prompt refused a command after program exit")
    let promptBack = await pump(until: { !session.isRunning && session.lines.last?.text == "after" })
    expect(promptBack, "echo after the program did not land in the scrollback")

    // -- Case 2: raw mode alone engages (the TUI-framework path — ink enables raw keys for
    // useInput before anything worth drawing). No output at all, and the flip must still be
    // visible on the session.
    let rawOnly = """
    process.stdin.setRawMode(true);
    process.stdin.on('data', (key) => { if (String(key) === 'q') process.exit(0); });
    """
    let (rawSession, rawBase) = makeSession(script: rawOnly, name: "raw")
    defer { try? FileManager.default.removeItem(at: rawBase) }
    _ = rawSession.run("node tui.js")
    let rawEngaged = await pump(until: { rawSession.programOnScreen })
    expect(rawEngaged, "setRawMode(true) did not engage the grid")
    _ = rawSession.sendKey("q")
    let rawEnded = await pump(until: { rawSession.program == nil })
    expect(rawEnded, "the raw-mode program did not exit on q")

    // -- Case 3: the control. A one-shot command stays in the scrollback; the grid stays out
    // of it entirely.
    let (echoSession, echoBase) = makeSession(script: nil, name: "echo")
    defer { try? FileManager.default.removeItem(at: echoBase) }
    _ = echoSession.run("echo hi")
    let echoDone = await pump(until: { !echoSession.isRunning })
    expect(echoDone, "echo never finished")
    expect(!echoSession.programOnScreen, "echo engaged the grid")
    expect(echoSession.program == nil, "echo launched a program")
    expect(echoSession.lines.last?.text == "hi", "echo's output missing from the scrollback")
    let blankGrid = (0..<echoSession.screen.rows).allSatisfy { echoSession.screen.text(row: $0).isEmpty }
    expect(blankGrid, "echo wrote to the grid")

    if failures == 0 {
        print("TUI INLINE MATCH — cursor-up repaint engages the grid and replaces rows in place,")
        print("  a mid-run keystroke reaches the program, exit restores the prompt with the last")
        print("  frame in history, and `echo hi` stays scrollback-only")
    } else {
        print("TUI INLINE FAILED — \(failures)")
        exit(1)
    }
}
await main()
