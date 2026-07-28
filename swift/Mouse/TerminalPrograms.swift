import Foundation

/// A full-screen terminal PROGRAM — the second thing the terminal can host.
///
/// The prompt-and-scrollback model runs a command to completion and appends what it said. A
/// program instead OWNS the screen and the keyboard for as long as it runs: it draws by
/// writing ANSI through `TerminalProgramIO.write`, receives every keystroke through `input`,
/// and ends by calling `io.exit`. This is Mouse's stand-in for a foreground process on a PTY
/// — iOS has no fork/exec, so a "process" is a Swift object honoring the same contract a
/// spawned binary would: stdout draws, stdin is keys, resize is SIGWINCH. Everything later on
/// the roadmap that runs interactively (agent CLIs, editors, wasm processes) enters the
/// terminal through this protocol.
///
/// Foundation-only by design: programs verify headlessly by wiring `write` into an
/// `AnsiParser` and asserting the grid (per AGENTS.md). Main-actor, like all UI-adjacent
/// state.
@MainActor
protocol TerminalProgram: AnyObject {
    /// Shown where the prompt lives while the program runs ("less README.md", "top").
    var title: String { get }
    /// Called once. Enter the alt screen first (`ESC[?1049h`) — the terminal renders the grid
    /// while a program is running — then paint.
    func start(io: TerminalProgramIO)
    /// One keystroke: a printable character, "\r", or an arrow key's escape sequence
    /// (`ESC[A`…). ^C arrives as "\u{3}"; programs decide what quitting means.
    func input(_ text: String)
    /// The visible grid changed size (rotation): adopt it and repaint.
    func resize(rows: Int, columns: Int)
}

/// The kernel side of a running program: its stdout, its exit(2), and the screen geometry it
/// was born with.
struct TerminalProgramIO {
    let rows: Int
    let columns: Int
    let write: @MainActor (String) -> Void
    let exit: @MainActor () -> Void
}

/// `less`/`more` — the pager, and the proof program for the screen model. Wraps long lines,
/// scrolls by line or page, and pins an inverse status bar to the bottom row, exactly the way
/// a real pager exercises a real terminal.
@MainActor
final class PagerProgram: TerminalProgram {
    let title: String
    private let lines: [String]
    private var wrapped: [String] = []
    /// First visible wrapped row.
    private var top = 0
    private var rows = 24
    private var columns = 80
    private var io: TerminalProgramIO?

    init(text: String, title: String) {
        self.title = title
        let body = text.hasSuffix("\n") ? String(text.dropLast()) : text
        self.lines = body.components(separatedBy: "\n")
    }

    func start(io: TerminalProgramIO) {
        self.io = io
        rows = io.rows
        columns = io.columns
        rewrap()
        io.write("\u{1b}[?1049h\u{1b}[?25l")
        draw()
    }

    func input(_ text: String) {
        switch text {
        case "q", "\u{3}": quit()
        case "j", "\r", "\n", "\u{1b}[B": scroll(1)
        case "k", "\u{1b}[A": scroll(-1)
        case " ", "f", "\u{1b}[6~": scroll(pageRows)
        case "b", "\u{1b}[5~": scroll(-pageRows)
        case "d": scroll(max(1, pageRows / 2))
        case "u": scroll(-max(1, pageRows / 2))
        case "g": top = 0; draw()
        case "G": top = maxTop; draw()
        default: break
        }
    }

    func resize(rows: Int, columns: Int) {
        self.rows = rows
        self.columns = columns
        rewrap()
        top = min(top, maxTop)
        draw()
    }

    /// Rows available to content — everything above the status bar.
    private var pageRows: Int { max(1, rows - 1) }
    private var maxTop: Int { max(0, wrapped.count - pageRows) }

    private func scroll(_ delta: Int) {
        let target = min(maxTop, max(0, top + delta))
        guard target != top else { return }
        top = target
        draw()
    }

    private func rewrap() {
        wrapped = lines.flatMap { line -> [String] in
            guard line.count > columns, columns > 0 else { return [line] }
            var chunks: [String] = []
            var rest = Substring(line)
            while rest.count > columns {
                chunks.append(String(rest.prefix(columns)))
                rest = rest.dropFirst(columns)
            }
            chunks.append(String(rest))
            return chunks
        }
        if wrapped.isEmpty { wrapped = [""] }
    }

    private func draw() {
        guard let io else { return }
        var out = "\u{1b}[H"
        for row in 0..<pageRows {
            let index = top + row
            out += "\u{1b}[2K"
            if index < wrapped.count { out += wrapped[index] }
            out += "\r\n"
        }
        let bottom = min(top + pageRows, wrapped.count)
        let percent = maxTop == 0 ? 100 : Int((Double(top) / Double(maxTop) * 100).rounded())
        var status = " \(title)  \(top + 1)-\(bottom)/\(wrapped.count)  \(percent)%  j/k space/b g/G q"
        status = String(status.prefix(columns))
        status += String(repeating: " ", count: max(0, columns - status.count))
        out += "\u{1b}[7m" + status + "\u{1b}[27m"
        io.write(out)
    }

    private func quit() {
        io?.write("\u{1b}[?25h\u{1b}[?1049l")
        io?.exit()
    }
}

/// `top` as a live program: repaints the same facts the one-shot builtin prints, on a
/// two-second tick, until 'q'. The stats stay in Shell.swift (they are shell truth); this
/// class owns only the drawing and the clock.
@MainActor
final class TopProgram: TerminalProgram {
    let title = "top"
    private let snapshot: @MainActor () -> [String]
    private var io: TerminalProgramIO?
    private var rows = 24
    private var columns = 80
    private var ticker: Task<Void, Never>?

    init(snapshot: @escaping @MainActor () -> [String]) {
        self.snapshot = snapshot
    }

    func start(io: TerminalProgramIO) {
        self.io = io
        rows = io.rows
        columns = io.columns
        io.write("\u{1b}[?1049h\u{1b}[?25l")
        draw()
        ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                self?.draw()
            }
        }
    }

    func input(_ text: String) {
        if text == "q" || text == "\u{3}" { quit() }
    }

    func resize(rows: Int, columns: Int) {
        self.rows = rows
        self.columns = columns
        draw()
    }

    private func draw() {
        guard let io else { return }
        var header = " top — every 2s, q quits"
        header = String(header.prefix(columns))
        header += String(repeating: " ", count: max(0, columns - header.count))
        var out = "\u{1b}[H\u{1b}[7m" + header + "\u{1b}[27m"
        // Address each row absolutely — a trailing newline on the bottom row would scroll.
        for (index, line) in snapshot().prefix(max(0, rows - 1)).enumerated() {
            out += "\u{1b}[\(index + 2);1H\u{1b}[2K" + String(line.prefix(columns))
        }
        out += "\u{1b}[J"
        io.write(out)
    }

    private func quit() {
        ticker?.cancel()
        io?.write("\u{1b}[?25h\u{1b}[?1049l")
        io?.exit()
    }
}
