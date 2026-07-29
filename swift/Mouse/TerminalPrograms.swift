import Foundation

/// A physical key, encoded to the bytes a terminal program reads on stdin. The keyboard
/// layer (`pressesBegan`, or the field's backspace) maps a hardware key to one of these; the
/// encoding is xterm's, so a TUI navigates with the arrows, edits with backspace, and reads
/// Ctrl-combos exactly as it would on a real terminal. Pure/Foundation, so it verifies in the
/// screen harness alongside the parser.
enum TerminalKey: Equatable {
    case up, down, right, left
    case home, end, pageUp, pageDown, insert, delete
    case backspace, tab, backTab, escape, enter
    case function(Int)        // F1…F12

    struct Modifiers: OptionSet {
        let rawValue: Int
        static let shift = Modifiers(rawValue: 1)
        static let alt   = Modifiers(rawValue: 2)
        static let ctrl  = Modifiers(rawValue: 4)
    }

    /// The byte sequence for this key. `modifiers` shapes cursor/navigation keys the xterm
    /// way (`ESC[1;<n><final>`, n = 1 + shift + 2·alt + 4·ctrl). `applicationCursor` is DECCKM
    /// (`ESC[?1h`): while set, the unmodified arrows/Home/End encode as SS3 (`ESC O <final>`)
    /// rather than CSI — modified keys always stay CSI, matching xterm.
    func encoded(_ modifiers: Modifiers = [], applicationCursor: Bool = false) -> String {
        let esc = "\u{1b}"
        // A letter-final cursor key: `ESC[<final>` (or SS3 `ESC O <final>` in application
        // mode), or `ESC[1;<n><final>` with modifiers.
        func letterKey(_ final: String) -> String {
            if modifiers.isEmpty { return applicationCursor ? "\(esc)O\(final)" : "\(esc)[\(final)" }
            return "\(esc)[1;\(1 + modifiers.rawValue)\(final)"
        }
        // A tilde-final navigation key: `ESC[<num>~`, or `ESC[<num>;<n>~` with modifiers.
        func tildeKey(_ num: Int) -> String {
            modifiers.isEmpty ? "\(esc)[\(num)~" : "\(esc)[\(num);\(1 + modifiers.rawValue)~"
        }
        switch self {
        case .up:       return letterKey("A")
        case .down:     return letterKey("B")
        case .right:    return letterKey("C")
        case .left:     return letterKey("D")
        case .home:     return letterKey("H")
        case .end:      return letterKey("F")
        case .insert:   return tildeKey(2)
        case .delete:   return tildeKey(3)
        case .pageUp:   return tildeKey(5)
        case .pageDown: return tildeKey(6)
        case .backspace: return "\u{7f}"          // DEL, what terminals send for Backspace
        case .tab:       return "\t"
        case .backTab:   return "\(esc)[Z"
        case .escape:    return esc
        case .enter:     return "\r"
        case .function(let n):
            switch n {
            case 1: return "\(esc)OP"
            case 2: return "\(esc)OQ"
            case 3: return "\(esc)OR"
            case 4: return "\(esc)OS"
            case 5: return "\(esc)[15~"
            case 6: return "\(esc)[17~"
            case 7: return "\(esc)[18~"
            case 8: return "\(esc)[19~"
            case 9: return "\(esc)[20~"
            case 10: return "\(esc)[21~"
            case 11: return "\(esc)[23~"
            case 12: return "\(esc)[24~"
            default: return ""
            }
        }
    }

    /// Ctrl+letter → its control byte (Ctrl-A = 0x01 … Ctrl-Z = 0x1a). Also the handful of
    /// symbol controls terminals define (`Ctrl-[` = ESC, `Ctrl-\`, `Ctrl-]`, `Ctrl-_`).
    static func control(for character: Character) -> String? {
        guard let ascii = character.asciiValue else { return nil }
        switch ascii {
        case 0x40...0x5f: return String(Unicode.Scalar(ascii & 0x1f))   // @A–Z[\]^_
        case 0x61...0x7a: return String(Unicode.Scalar((ascii - 0x20) & 0x1f)) // a–z
        case 0x20: return "\u{0}"     // Ctrl-Space → NUL
        default: return nil
        }
    }
}

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
    /// True when this program draws on the SCREEN (alt screen / raw keys); false while it
    /// merely streams lines, which belong in the scrollback. `less` and `top` are always
    /// true; a Node program decides at runtime — `node build.js` prints, `node tui.js` draws.
    var rendersScreen: Bool { get }
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
    let rendersScreen = true
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
    let rendersScreen = true
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

/// A Node program holding the terminal: the join between phase T (the screen) and phase G
/// (the runtime). JavaScript writes go through the host's ANSI parser, keystrokes reach
/// `process.stdin`, and rotation is a real `resize` event — so a CLI written for a TTY
/// behaves as it would on one.
///
/// Mode is decided by the program, not by us: output stays in the SCROLLBACK until the
/// script asks for raw keys (`stdin.setRawMode(true)`) or switches to the alt screen, at
/// which point the grid takes over. `node build.js` prints lines like any command;
/// `node tui.js` draws. That is exactly the two-mode rule real terminals follow.
@MainActor
final class NodeProgram: TerminalProgram {
    let title: String
    private(set) var rendersScreen = false

    /// Called per complete output line while the program is in TRANSCRIPT mode (screen-mode
    /// writes feed the grid through `io.write` instead). Escapes are stripped: the
    /// scrollback renders plain text.
    private let transcript: (String, _ isError: Bool) -> Void
    private let onExit: () -> Void
    private let engine: NodeEngine
    private let source: String
    private let path: String
    private let argv: [String]
    private let cwd: String
    private var io: TerminalProgramIO?
    private var task: Task<Void, Never>?
    /// Raw mode = keystrokes are bytes, ^C included; cooked mode = ^C is SIGINT.
    private var rawMode = false
    /// Transcript text still waiting for its newline.
    private var pendingLine = ""
    private var pendingLineIsError = false

    /// The caller builds the engine (it owns root/env/shell); the program attaches the TTY.
    init(title: String, source: String, path: String, argv: [String], cwd: String,
         engine: NodeEngine,
         transcript: @escaping (String, _ isError: Bool) -> Void,
         onExit: @escaping () -> Void) {
        self.title = title
        self.source = source
        self.path = path
        self.argv = argv
        self.cwd = cwd
        self.engine = engine
        self.transcript = transcript
        self.onExit = onExit
    }

    func start(io: TerminalProgramIO) {
        self.io = io
        // Attached here, not in init: the program is born knowing the grid it draws into —
        // a TUI measures process.stdout.columns in its first breath.
        // The closures hop to the main actor: the engine calls them from its JS thread.
        engine.attachTTY(NodeEngine.TTY(
            write: { [weak self] text in Task { @MainActor in self?.receive(text, isError: false) } },
            writeError: { [weak self] text in Task { @MainActor in self?.receive(text, isError: true) } },
            rows: io.rows,
            columns: io.columns,
            rawModeChanged: { [weak self] raw in Task { @MainActor in self?.rawModeChanged(raw) } }
        ))
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await self.engine.run(source: self.source, path: self.path,
                                               argv: self.argv, cwd: self.cwd, stdin: "")
            // TTY writes streamed live; what's left in the result is the crash report
            // (a fatal exception's stack lands there, not in the stream).
            if !result.err.isEmpty { self.receive(result.err, isError: true) }
            self.flushPendingLine()
            if self.rendersScreen {
                // Leave the screen the way a well-behaved program would.
                self.io?.write("\u{1b}[?25h\u{1b}[?1049l")
            }
            self.onExit()
            self.io?.exit()
        }
    }

    func input(_ text: String) {
        // The terminal discipline: cooked-mode ^C is a signal (handlers or death), raw-mode
        // ^C is just a byte the program reads.
        if text == "\u{3}", !rawMode {
            engine.interrupt()
        } else {
            engine.deliverInput(text)
        }
    }

    func resize(rows: Int, columns: Int) {
        engine.resizeTTY(rows: rows, columns: columns)
    }

    private func rawModeChanged(_ raw: Bool) {
        rawMode = raw
        // Raw keys mean the program is drawing its own UI (ink repaints in place, no alt
        // screen) — the grid takes over from here.
        if raw { enterScreenMode() }
    }

    /// Output from the engine (already hopped to the main actor).
    private func receive(_ text: String, isError: Bool) {
        if !rendersScreen, text.contains("\u{1b}[?1049h") || text.contains("\u{1b}[?1047h") || text.contains("\u{1b}[?47h") {
            enterScreenMode()
        }
        if rendersScreen {
            // ONLCR, the TTY's job, not the emulator's: a real PTY maps NL→CR-NL on output,
            // so a program that ends lines with a bare `\n` (ink's inline frames, every
            // logUpdate-style repaint) lands each line at column 0. Without it the screen —
            // correctly xterm-faithful, LF is index — shears the frame diagonally. We are
            // the PTY substitute, so the translation belongs here.
            io?.write(Self.onlcr(text))
            return
        }
        // Transcript mode: line-buffer, and emit complete lines with escapes stripped.
        // Scalar-level splitting: to Swift, "\r\n" is ONE Character, invisible to a
        // Character-level search for "\n".
        if pendingLineIsError != isError { flushPendingLine() }
        pendingLineIsError = isError
        pendingLine += text
        while let newline = pendingLine.unicodeScalars.firstIndex(of: "\n") {
            let scalars = pendingLine.unicodeScalars
            let line = String(String.UnicodeScalarView(scalars[..<newline]))
            pendingLine = String(String.UnicodeScalarView(scalars[scalars.index(after: newline)...]))
            transcript(Self.strippingEscapes(line), isError)
        }
    }

    private func flushPendingLine() {
        guard !pendingLine.isEmpty else { return }
        transcript(Self.strippingEscapes(pendingLine), pendingLineIsError)
        pendingLine = ""
    }

    /// The program took the screen: the scrollback keeps what it already said (like a shell
    /// keeps its history when vim opens), and the grid gets everything from here on.
    private func enterScreenMode() {
        guard !rendersScreen else { return }
        flushPendingLine()
        rendersScreen = true
    }

    /// ONLCR: a bare `\n` (not already preceded by `\r`) becomes `\r\n`. A stray `\r\n`
    /// split across two writes yields a harmless `\r\r\n` (CR to column 0 is idempotent),
    /// so no cross-chunk state is needed.
    static func onlcr(_ text: String) -> String {
        guard text.unicodeScalars.contains("\n") else { return text }
        var result = String.UnicodeScalarView()
        result.reserveCapacity(text.unicodeScalars.count + 8)
        var previous: Unicode.Scalar = "\0"
        for scalar in text.unicodeScalars {
            if scalar == "\n", previous != "\r" { result.append("\r") }
            result.append(scalar)
            previous = scalar
        }
        return String(result)
    }

    /// Drop ANSI escape sequences (CSI, OSC, and two-byte ESC forms) and carriage returns —
    /// the scrollback is plain text. Scalar-level for the same CRLF reason as above.
    static func strippingEscapes(_ text: String) -> String {
        var result = String.UnicodeScalarView()
        var iterator = text.unicodeScalars.makeIterator()
        while let scalar = iterator.next() {
            if scalar == "\r" { continue }
            guard scalar == "\u{1b}" else { result.append(scalar); continue }
            guard let kind = iterator.next() else { break }
            if kind == "[" {
                // CSI: parameters and intermediates end at a final byte @–~.
                while let byte = iterator.next() {
                    if (0x40...0x7e).contains(byte.value) { break }
                }
            } else if kind == "]" {
                // OSC: runs to BEL or ESC \.
                var previous = kind
                while let byte = iterator.next() {
                    if byte.value == 0x7 { break }
                    if previous == "\u{1b}", byte == "\\" { break }
                    previous = byte
                }
            }
            // Two-byte forms (ESC =, ESC >, …): the kind byte itself is consumed.
        }
        return String(result)
    }
}
