import Foundation

// ink draws a bordered box around CJK and emoji. That is the width question in one frame: ink
// measures each row with `string-width` and decides where the right border goes, so the frame
// is square only if the engine running it agrees about how wide 日本語 and 🎉 are.
//
// Driven through the TTY path, which is how a TUI actually runs here — ink's first frame lands
// in the transcript before the raw-mode flip, and that frame is what gets compared, line for
// line, against real node rendering the same app. The GRID's own placement of wide characters
// is gated separately by widechars and widetui; this is about the library's measurements
// surviving the engine.
@MainActor
final class Host {
    let screen: TerminalScreen
    let parser: AnsiParser
    let program: NodeProgram
    var lines: [String] = []
    /// Kept rather than dropped: a program that renders NOTHING has usually said why on stderr,
    /// and a harness that discards those lines reports the silence instead of the reason.
    var problems: [String] = []
    var exited = false

    init(source: String, root: URL, rows: Int = 14, columns: Int = 44) {
        screen = TerminalScreen(rows: rows, columns: columns)
        parser = AnsiParser(screen: screen)
        let engine = NodeEngine(root: root, env: ["TERM": "xterm-256color", "PATH": "/usr/bin"])
        var sink: ((String, Bool) -> Void)!
        program = NodeProgram(title: "node app.js", source: source, path: "/app.js",
                              argv: ["node", "/app.js"], cwd: "/", engine: engine,
                              transcript: { line, isError in sink(line, isError) }, onExit: {})
        sink = { [weak self] line, isError in
            if isError { self?.problems.append(line) } else { self?.lines.append(line) }
        }
        parser.respond = { [weak self] reply in self?.program.input(reply) }
        program.start(io: TerminalProgramIO(rows: rows, columns: columns,
                                            write: { [weak self] text in self?.parser.feed(text) },
                                            exit: { [weak self] in self?.exited = true }))
    }
    func pump(until ready: () -> Bool, seconds: Double = 180) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if ready() { return true }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        return ready()
    }
}

@MainActor
func main() async {
    let here = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let project = here.appendingPathComponent("project")
    let source = (try? String(contentsOf: project.appendingPathComponent("app.js"), encoding: .utf8)) ?? ""
    let expected = ((try? String(contentsOf: here.appendingPathComponent("node.txt"), encoding: .utf8)) ?? "")
        .split(separator: "\n").map(String.init)

    let host = Host(source: source, root: project)
    let drew = host.pump(until: { host.lines.contains { $0.contains("└") } })
    if !drew {
        print("  ink never emitted a closing border; saw \(host.lines.count) lines")
        for line in host.lines.prefix(6) { print("    |\(line)|") }
        for line in host.problems.prefix(12) { print("    stderr: \(line)") }
        print("INK WIDE FAILED"); exit(1)
    }

    // The frame is the run of lines from the top border to the bottom one.
    guard let top = host.lines.firstIndex(where: { $0.contains("┌") }),
          let bottom = host.lines.firstIndex(where: { $0.contains("└") }), bottom >= top else {
        print("  no complete frame"); print("INK WIDE FAILED"); exit(1)
    }
    let frame = Array(host.lines[top...bottom])
    var bad = 0
    for i in 0..<max(expected.count, frame.count) {
        let want = i < expected.count ? expected[i] : "<missing>"
        let got = i < frame.count ? frame[i] : "<missing>"
        if want != got { print("  node: |\(want)|\n  ours: |\(got)|"); bad += 1 }
    }
    // A frame is only correct if every row is the same DISPLAY width — that is what makes the
    // borders a rectangle, and what a width disagreement destroys.
    var widths = Set<Int>()
    for line in frame { widths.insert(line.reduce(0) { $0 + TerminalWidth.columns(of: $1) }) }
    if widths.count != 1 { print("  ragged frame — row widths: \(widths.sorted())"); bad += 1 }

    if bad == 0 {
        print("INK WIDE MATCH — ink's bordered frame over CJK and emoji is identical to node's,")
        print("  and all \(frame.count) rows measure \(widths.first ?? 0) columns")
    } else {
        print("INK WIDE FAILED — \(bad)")
        exit(1)
    }
}
await main()
