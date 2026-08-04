import Foundation
setvbuf(stdout, nil, _IONBF, 0)

// End to end, phase G into phase T: a Node program on a real TTY drives the phase-T screen, and
// the grid must count COLUMNS. This is the path the standing work is about.
//
// The earlier attempt at this test failed for a reason worth writing down. It let the program
// run to completion and then read the screen — but a full-screen program RESTORES the screen on
// exit (correctly, now), so there was nothing left to read. Working around that with a poll loop
// failed too, because the program writes and exits synchronously. The honest fix is to test what
// a TUI actually does: draw, then WAIT for input. The frame stays up, the assertions run against
// the live grid, and a keystroke ends it — which also exercises the stdin half of the wiring.
@MainActor
final class Host {
    let screen: TerminalScreen
    let parser: AnsiParser
    let program: NodeProgram
    var exited = false

    init(source: String, root: URL, rows: Int = 10, columns: Int = 40) {
        screen = TerminalScreen(rows: rows, columns: columns)
        parser = AnsiParser(screen: screen)
        let engine = NodeEngine(root: root, env: ["TERM": "xterm-256color"])
        program = NodeProgram(title: "node t.js", source: source, path: "/t.js",
                              argv: ["node", "/t.js"], cwd: "/", engine: engine,
                              transcript: { _, _ in }, onExit: {})
        parser.respond = { [weak self] reply in self?.program.input(reply) }
        program.start(io: TerminalProgramIO(rows: rows, columns: columns,
                                            write: { [weak self] text in self?.parser.feed(text) },
                                            exit: { [weak self] in self?.exited = true }))
    }

    /// Pump until `ready` holds, so assertions run on a drawn frame rather than a race.
    func pump(until ready: () -> Bool, seconds: Double = 5.0) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if ready() { return true }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        return ready()
    }
    func row(_ index: Int) -> String {
        String(screen.grid[index].filter { !$0.isContinuation }.map(\.character))
            .replacingOccurrences(of: " +$", with: "", options: .regularExpression)
    }
    func cell(_ row: Int, _ column: Int) -> Character { screen.grid[row][column].character }
}

@MainActor
func main() async {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    var failures = 0
    func expect(_ label: String, _ got: String, _ want: String) {
        if got != want { print("  \(label): want \(want.debugDescription) got \(got.debugDescription)"); failures += 1 }
    }

    // Shaped like ink: alt screen, raw keys, draw a frame, then wait.
    let source = """
    process.stdout.write('\\u001b[?1049h\\u001b[H');
    process.stdin.setRawMode(true);
    process.stdout.write('|abcd|\\r\\n');
    process.stdout.write('|中文|\\r\\n');
    process.stdout.write('|a中b|\\r\\n');
    process.stdout.write('\\u001b[5;1H日本語');
    process.stdout.write('\\u001b[5;7Hok');
    // A TUI draws and waits. The frame stays up until a key arrives.
    process.stdin.on('data', (key) => {
      if (String(key) === 'q') { process.stdout.write('\\u001b[?1049l'); process.exit(0); }
    });
    """
    let host = Host(source: source, root: root)
    let drawn = host.pump(until: { host.screen.grid.count > 4
                                   && host.screen.grid[4].contains { $0.character != " " } })
    if !drawn {
        print("  the program never drew its frame"); print("WIDE TUI FAILED"); exit(1)
    }

    expect("latin row", host.row(0), "|abcd|")
    expect("cjk row", host.row(1), "|中文|")
    expect("mixed row", host.row(2), "|a中b|")
    // The whole point: the closing bar lands in the SAME column on every row. One column per
    // character puts it at 3 on the CJK row and the box comes out ragged.
    expect("latin close column", String(host.cell(0, 5)), "|")
    expect("cjk close column", String(host.cell(1, 5)), "|")
    expect("mixed close column", String(host.cell(2, 5)), "|")
    // Absolute positioning agrees with the same arithmetic: 日本語 is six columns.
    expect("wide then positioned", host.row(4), "日本語ok")
    expect("positioned lands at 6", String(host.cell(4, 6)), "o")

    // The stdin half: a keystroke reaches the program, which leaves the alt screen and exits.
    host.program.input("q")
    let quit = host.pump(until: { host.exited })
    if !quit { print("  the program did not exit on a keystroke"); failures += 1 }

    if failures == 0 {
        print("WIDE TUI MATCH — a Node program's boxes align on the phase-T screen, Latin and CJK alike,")
        print("  and a keystroke through stdin ends it")
    } else {
        print("WIDE TUI FAILED — \(failures)")
        exit(1)
    }
}
await main()
