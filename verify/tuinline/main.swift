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
/// SwiftUI's observation shape, headlessly: register on `screenGeneration`, and on change
/// re-arm from the main actor (as a view re-subscribes on its next body evaluation). Fires
/// counted here are display-refresh OPPORTUNITIES — a frame that lands on the grid without
/// one is a frame the app would never show, which is exactly the class of bug a grid-only
/// assertion cannot catch.
@MainActor
final class ObservationProbe {
    private let session: TerminalSession
    private(set) var fires = 0
    init(_ session: TerminalSession) { self.session = session; arm() }
    private func arm() {
        withObservationTracking({ _ = self.session.screenGeneration }, onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.fires += 1
                self.arm()
            }
        })
    }
}

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

/// A NodeProgram host that records every `io.write` arrival verbatim — the probe for the
/// delivery-order contract (case 5). No parser, no session: the recording IS the assertion.
@MainActor
final class BurstHost {
    let program: NodeProgram
    var recorded = ""
    var exited = false
    init(source: String, root: URL) {
        let engine = NodeEngine(root: root, env: ["TERM": "xterm-256color"])
        program = NodeProgram(title: "node burst.js", source: source, path: "/burst.js",
                              argv: ["node", "/burst.js"], cwd: "/", engine: engine,
                              transcript: { _, _ in }, onExit: {})
        program.start(io: TerminalProgramIO(rows: 10, columns: 60,
                                            write: { [weak self] text in self?.recorded += text },
                                            exit: { [weak self] in self?.exited = true }))
    }
}

@MainActor
func echoBaseFor(_ name: String) -> URL {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("tuinline-\(name)-\(getpid())")
    try? FileManager.default.removeItem(at: base)
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return base
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

    // -- Case 3: the real thing, at typing speed. @clack/prompts (create-vite's prompt
    // library) runs a text prompt through its own plumbing: a `new tty.WriteStream(0)` sink
    // whose overridden `_write` is where it reads `rl.line` to track the typed value, stdin
    // piped into that sink, readline echoing into it. Eight keystrokes fired back-to-back
    // with no yields between them — the phone's fast typing — must ALL land in the frame,
    // with no echo fragments sprayed under it, and Enter must advance and submit. A single
    // slow keystroke passed while this exact flow was broken on the phone; the storm is the
    // test.
    let project = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("project")
    try? FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    // Installed HERE on first run, by the engine's own package manager — node_modules is not
    // checked in, and a harness that assumes someone else's tree passes for the wrong reason.
    if !FileManager.default.fileExists(atPath: project.appendingPathComponent("node_modules").path) {
        print("installing @clack/prompts with our own package manager…")
        do { _ = try await PackageManager.install(requirements: ["@clack/prompts": "^0.7.0"], into: project) }
        catch {
            print("  install: \(error)")
            print("TUI INLINE FAILED — install")
            exit(1)
        }
    }
    let clackApp = """
    const { text, select, isCancel } = require('@clack/prompts');
    (async () => {
      const name = await text({ message: 'Project name:', placeholder: 'vite-project' });
      if (isCancel(name)) process.exit(1);
      const fw = await select({
        message: 'Select a framework:',
        options: [
          { value: 'vanilla', label: 'Vanilla' },
          { value: 'vue', label: 'Vue' },
        ],
      });
      if (isCancel(fw)) process.exit(1);
      console.log('DONE name=' + name + ' fw=' + fw);
      process.exit(0);
    })();
    """
    try? clackApp.write(to: project.appendingPathComponent("app.js"), atomically: true, encoding: .utf8)
    let clack = TerminalSession(root: project)
    clack.setGridSize(rows: 14, columns: 60)
    _ = clack.run("node app.js")
    let clackUp = await pump(until: { clack.screen.plainText.contains("Project name") }, seconds: 120)
    expect(clackUp, "the clack prompt never drew")
    if clackUp {
        let linesBefore = clack.lines.count
        for key in ["p", "h", "o", "n", "e", "a", "p", "p"] { _ = clack.sendKey(key) }
        let allTyped = await pump(until: { clack.screen.plainText.contains("phoneapp") }, seconds: 20)
        expect(allTyped, "rapid keystrokes lost: grid shows \(clack.screen.plainText.split(separator: "\n").filter { !$0.isEmpty })")
        // The value replaced the placeholder INSIDE the frame; nothing leaked below it.
        let rows = (0..<clack.screen.rows).map { clack.screen.text(row: $0) }
        if let frameEnd = rows.lastIndex(where: { $0.hasPrefix("└") }) {
            for row in (frameEnd + 1)..<rows.count {
                expect(rows[row].isEmpty, "echo artifacts under the frame at row \(row): |\(rows[row])|")
            }
        } else {
            expect(false, "no frame edge on the grid")
        }
        expect(clack.lines.count == linesBefore,
               "typing leaked into the scrollback (\(linesBefore) → \(clack.lines.count) lines)")
        _ = clack.sendKey("\r")
        let selectUp = await pump(until: { clack.screen.plainText.contains("Select a framework") }, seconds: 20)
        expect(selectUp, "Enter did not advance to the select prompt")
        _ = clack.sendKey("\r")
        let clackDone = await pump(until: { clack.program == nil }, seconds: 20)
        expect(clackDone, "the clack flow never exited")
        expect(clack.lines.contains { $0.text == "DONE name=phoneapp fw=vanilla" },
               "the typed value did not survive to submit: \(clack.lines.suffix(3).map(\.text))")
    }

    // -- Case 4: create-vite itself, the device scenario — a small grid, eight rapid keys,
    // and the prompt-to-prompt TRANSITION. Its bundled prompt library builds
    // `createInterface({ input, terminal: true })` with NO output — a silent line editor in
    // real node — and the readline output-defaulting bug echoed every keystroke (and Enter's
    // CR-LF) into the live frame region: "p⟶honeapp" under the frame on the phone. Gated
    // here: typed value in the frame, nothing under the frame, and the Enter transition both
    // REACHES the grid and FIRES observation — a frame present but never published is one
    // the app would never display.
    if !FileManager.default.fileExists(atPath: project.appendingPathComponent("node_modules/create-vite").path) {
        print("installing create-vite with our own package manager…")
        do { _ = try await PackageManager.install(requirements: ["create-vite": "^9.1.0"], into: project) }
        catch {
            print("  install: \(error)")
            print("TUI INLINE FAILED — install")
            exit(1)
        }
    }
    let vite = TerminalSession(root: project)
    vite.setGridSize(rows: 8, columns: 44)
    let probe = ObservationProbe(vite)
    _ = vite.run("npx create-vite")
    let viteUp = await pump(until: { vite.screen.plainText.contains("Project name") }, seconds: 120)
    expect(viteUp, "create-vite's prompt never drew")
    if viteUp {
        for key in ["p", "h", "o", "n", "e", "a", "p", "p"] { _ = vite.sendKey(key) }
        let viteTyped = await pump(until: { vite.screen.plainText.contains("phoneapp") }, seconds: 20)
        expect(viteTyped, "rapid keystrokes lost in create-vite's prompt")
        // Nothing echoed under the frame — the artifact row the phone showed.
        let viteRows = (0..<vite.screen.rows).map { vite.screen.text(row: $0) }
        if let frameEnd = viteRows.lastIndex(where: { $0.hasPrefix("└") }) {
            for row in (frameEnd + 1)..<viteRows.count {
                expect(viteRows[row].isEmpty, "keystroke echo under the frame at row \(row): |\(viteRows[row])|")
            }
        } else {
            expect(false, "no frame edge on create-vite's grid")
        }
        let firesBeforeEnter = probe.fires
        _ = vite.sendKey("\r")
        let transition = await pump(until: { vite.screen.plainText.contains("Select a framework") }, seconds: 20)
        expect(transition, "the Enter transition never reached the grid")
        // Give the last hop's re-armed registration a beat, then judge.
        _ = await pump(until: { probe.fires > firesBeforeEnter }, seconds: 5)
        expect(probe.fires > firesBeforeEnter,
               "the transition landed on the grid without a single observation fire — invisible to the app")
        vite.interrupt()
        let viteEnded = await pump(until: { vite.program == nil }, seconds: 20)
        expect(viteEnded, "create-vite did not stop on ^C")
        expect(vite.run("echo back"), "the prompt refused a command after create-vite")
        let backAgain = await pump(until: { !vite.isRunning && vite.lines.last?.text == "back" })
        expect(backAgain, "echo after create-vite did not land in the scrollback")
    }

    // -- Case 5: delivery ORDER under burst writes from the engine thread. The engine emits
    // from its JS thread; the terminal applies on the main actor. 60 interleaved
    // stdout/stderr write pairs must arrive concatenated in exactly production order — any
    // reorder, loss, or duplication breaks the equality. This is the contract whose absence
    // let a burst of prompt frames apply out of order on the phone: the display settled on
    // whichever frame happened to land LAST, which reads as a freeze at a stale frame.
    let burstBase = echoBaseFor("burst")
    defer { try? FileManager.default.removeItem(at: burstBase) }
    let burst = BurstHost(source: """
        process.stdin.setRawMode(true);
        for (let i = 0; i < 60; i++) {
          process.stdout.write('S' + i + ';');
          process.stderr.write('E' + i + ';');
        }
        process.exit(0);
        """, root: burstBase)
    let burstDone = await pump(until: { burst.exited }, seconds: 30)
    expect(burstDone, "the burst program never exited")
    let expected = (0..<60).map { "S\($0);E\($0);" }.joined()
    if !burst.recorded.hasPrefix(expected) {
        expect(false, "burst writes arrived out of order or incomplete")
        // The first divergence, for the log.
        let got = burst.recorded.prefix(expected.count)
        for (index, pair) in zip(expected, got).enumerated() where pair.0 != pair.1 {
            print("    first divergence at offset \(index): want \(pair.0) got \(pair.1)")
            break
        }
    }

    // -- Case 6: the control. A one-shot command stays in the scrollback; the grid stays out
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
        print("  a mid-run keystroke reaches the program, a @clack prompt takes eight rapid")
        print("  keystrokes into its frame and submits them, create-vite's Enter transition")
        print("  reaches the grid observably with nothing echoed under the frame, 120 burst")
        print("  writes from the engine thread arrive in production order, exit restores the")
        print("  prompt with the last frame in history, and `echo hi` stays scrollback-only")
    } else {
        print("TUI INLINE FAILED — \(failures)")
        exit(1)
    }
}
await main()
