// The terminal's LOGIC, split from its SwiftUI views so it can be verified without a screen.
// The session was unreachable by every harness because it shared a file with `UIFont`, and a
// terminal that silently dropped a command's output shipped through a fully green suite as a
// result. What cannot be built headlessly cannot be gated.
import SwiftUI
import JavaScriptCore

/// The Terminal container (kind 5): a real terminal in look and feel — prompt, scrollback,
/// mono — with switchable ENGINES behind one prompt (the top-left chip cycles them):
///
///   msh — Mouse's from-scratch POSIX-flavored shell (`Shell.swift`): pipes, redirection,
///         quoting, variables, globs, history. iOS has no fork/exec, so a native shell is
///         the honest terminal (the a-Shell model); `git`/`npm` engines arrive per roadmap.
///   js  — JavaScriptCore REPL (system framework): evaluate JS with a persistent context,
///         `console.log` captured to scrollback.
///
/// Engines that need real processes (ssh; Android's `/system/bin/sh` in the Kotlin app)
/// join the same switcher rather than living inside msh. Output wraps, scrollback scrolls
/// vertically, taps focus the prompt — all per the gesture law.
@MainActor
@Observable
final class TerminalSession {
    struct Line: Identifiable {
        enum Kind {
            case command, output, error
        }

        let id = UUID()
        let text: String
        let kind: Kind
    }

    enum Engine: String, CaseIterable {
        case msh
        case js
    }

    let root: URL
    private(set) var lines: [Line] = []
    var engine: Engine = .msh
    /// True while a command is executing. Streaming commands (ping) hold this for their whole
    /// run; any keypress at the prompt interrupts — the phone's Ctrl-C.
    private(set) var isRunning = false

    /// The full-screen program owning the terminal right now (less, top), or nil at the
    /// prompt. While set, every keystroke routes to the program — the foreground-process
    /// model without fork/exec.
    private(set) var program: TerminalProgram?
    /// True while the running program DRAWS ON THE GRID — the observable truth the view keys
    /// its two modes on. This is a session property, not `program?.rendersScreen`, because a
    /// Node program flips `rendersScreen` mid-run on a plain (non-observable) object: SwiftUI
    /// never saw the flip, kept rendering the scrollback, and a TUI drew on a grid nobody
    /// displayed — ink UIs piling up as text at the bottom of the phone's terminal while
    /// keystrokes repainted an invisible screen. Updated at launch, on the program's
    /// `modeChanged` call, and at exit.
    private(set) var programOnScreen = false
    /// Whether the current program ever used the ALTERNATE screen. An alt-screen program
    /// (less, vim) restores the normal screen on exit — nothing to keep. An inline TUI (ink)
    /// leaves its last frame ON the normal screen, and a real terminal keeps that frame in
    /// history — see `programExited`.
    @ObservationIgnored private var programUsedAltScreen = false
    /// The grid a program draws into; its output feeds through `parser`.
    let screen = TerminalScreen()
    /// Bumped on every program write so SwiftUI redraws the grid (TerminalScreen itself is
    /// deliberately not observable — it's a Foundation engine).
    private(set) var screenGeneration = 0
    @ObservationIgnored private lazy var parser = AnsiParser(screen: screen)
    /// Last geometry the container measured; programs are born at this size.
    @ObservationIgnored private var gridRows = 24
    @ObservationIgnored private var gridColumns = 80

    let shell = MouseShell()
    @ObservationIgnored private lazy var javascript = JSEngine()
    @ObservationIgnored private var runningTask: Task<Void, Never>?

    init(root: URL) {
        self.root = root
    }

    var prompt: String {
        switch engine {
        case .msh: (shell.cwd.isEmpty ? "~" : "~/" + shell.cwd) + " $"
        case .js: "js>"
        }
    }

    /// Cycle to the next engine (the switcher chip's action).
    func switchEngine() {
        let all = Engine.allCases
        engine = all[(all.firstIndex(of: engine)! + 1) % all.count]
        append("[engine: \(engine.rawValue)]", .output)
    }

    /// What a command may reach OUTSIDE the terminal: mark a file dirty, open one, refresh the
    /// tree, refresh history. Four closures rather than the view models themselves — the session
    /// used to name `Workspace` and `CarouselDeck` in its signature, which dragged the whole
    /// view layer (and UIKit) behind it and put this file beyond the reach of every harness.
    struct Hooks {
        var markModified: (String) -> Void = { _ in }
        var openFile: (String) -> Void = { _ in }
        var reloadTree: () -> Void = {}
        var historyChanged: () -> Void = {}
        /// Identity for `git push`; nil when signed out. A closure for the same reason as the
        /// rest — the session should not reach for an app-wide singleton it cannot be tested
        /// without.
        var githubToken: () -> String? = { nil }
        var githubLogin: () -> String? = { nil }
        init(markModified: @escaping (String) -> Void = { _ in },
             openFile: @escaping (String) -> Void = { _ in },
             reloadTree: @escaping () -> Void = {},
             historyChanged: @escaping () -> Void = {},
             githubToken: @escaping () -> String? = { nil },
             githubLogin: @escaping () -> String? = { nil }) {
            self.markModified = markModified
            self.openFile = openFile
            self.reloadTree = reloadTree
            self.historyChanged = historyChanged
            self.githubToken = githubToken
            self.githubLogin = githubLogin
        }
    }

    /// Returns false when the input was refused (a command is already running) so the prompt
    /// field can keep its text.
    /// `screenless`: the caller has no grid to give a full-screen program. The Agent container
    /// is the case — it renders a conversation, not a terminal — and without this a print-mode
    /// invocation like `claude -p` is handed the screen it never asked for and never returns.
    @discardableResult
    func run(_ raw: String, hooks: Hooks = Hooks(), screenless: Bool = false) -> Bool {
        guard !isRunning, program == nil else { return false }
        let command = raw.trimmingCharacters(in: .whitespaces)
        append("\(prompt) \(command)", .command)
        guard !command.isEmpty else { return true }
        switch engine {
        case .msh: runShell(command, hooks: hooks, screenless: screenless)
        case .js: runJavaScript(command)
        }
        return true
    }

    /// Interrupt a running command (any keypress triggers this). Prints the classic ^C
    /// immediately; the command's own cancellation cleanup (ping's statistics line) follows
    /// as it winds down.
    /// When `canc` last sent a program ^C — the arming half of the two-press kill.
    private var interruptedAt: Date?

    func interrupt() {
        if let program {
            // ^C is a keystroke to a program — it decides what to do (and the host stops it
            // when it has no SIGINT handler of its own). That is the law's answer, and it has
            // a hole a real package fell into: a program that finished its work but left a
            // raw-mode stdin listener alive (`sv`'s closing screen) reads the byte and does
            // nothing, forever, and the terminal is held hostage. So a SECOND canc within ten
            // seconds is the shell's answer: take the terminal back. A real terminal's close
            // button, worn by canc on the second press. Ten, not two: the real cadence is
            // tap, wait to see whether anything happened, tap again — and a window sized to
            // a double-tap re-armed instead of killing, which was measured, not guessed.
            if let at = interruptedAt, Date().timeIntervalSince(at) < 10 {
                interruptedAt = nil
                forceStop(program)
                return
            }
            interruptedAt = Date()
            program.input("\u{3}")
            return
        }
        guard isRunning else { return }
        append("^C", .command)
        runningTask?.cancel()
    }

    /// Take the terminal back without asking the program first. The program does not get a vote
    /// here, unlike `interrupt`'s first press: this is the close button.
    private func forceStop(_ program: TerminalProgram) {
        append("killed \(program.title)", .error)
        program.terminate()
        // Termination flows through the program's own exit path (io.exit → the session's
        // cleanup), which is what keeps engines from leaking. A program too far gone to run even
        // that still must not keep the screen: reclaim it directly after a beat, if the same
        // program is somehow still installed.
        let held = ObjectIdentifier(program as AnyObject)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, let current = self.program,
                  ObjectIdentifier(current as AnyObject) == held else { return }
            self.programExited()
        }
    }

    /// Leaving the project takes its terminal with it. A program started here belongs to the
    /// workspace that is going away — a dev server left running would hold its port with nothing
    /// on screen able to reach it, which is the "a running program could not be stopped at all"
    /// trap in a new costume. So it is stopped outright rather than sent a ^C it may ignore;
    /// vite, for one, treats ^C as a keystroke and keeps serving.
    func stopForProjectChange() {
        if let program { forceStop(program) }
        runningTask?.cancel()
    }

    // MARK: - Full-screen programs

    /// Adopt a program: size the screen, hand it its IO, and give it the keyboard. Refused
    /// (in the scrollback, honestly) if one is already running.
    func launch(_ program: TerminalProgram) {
        guard self.program == nil else {
            report("\(program.title): a program is already running")
            return
        }
        screen.resize(rows: gridRows, columns: gridColumns)
        // A fresh program gets a fresh screen: leave any stranded alt screen, show the
        // cursor, drop DECCKM/bracketed paste, then RIS. Programs are also fed to the grid
        // while still in transcript mode (the engagement shadow — TerminalPrograms.swift),
        // so leftovers from the last program would otherwise sit under the new one's frame.
        parser.feed("\u{1b}[?1049l\u{1b}[?25h\u{1b}[?1l\u{1b}[?2004l\u{1b}c")
        self.program = program
        programOnScreen = program.rendersScreen
        programUsedAltScreen = false
        screenGeneration += 1
        // Terminal query replies (DSR/DA/DECRQM) travel back to the program as keystrokes —
        // the same path a real tty answers on. A program probing cursor position or feature
        // support gets its answer and proceeds instead of blocking on stdin.
        parser.respond = { [weak program] reply in program?.input(reply) }
        program.start(io: TerminalProgramIO(
            rows: gridRows,
            columns: gridColumns,
            write: { [weak self] text in
                guard let self else { return }
                self.parser.feed(text)
                if self.screen.isAlternate { self.programUsedAltScreen = true }
                self.screenGeneration += 1
            },
            exit: { [weak self] in self?.programExited() },
            modeChanged: { [weak self] in
                guard let self, let program = self.program else { return }
                self.programOnScreen = program.rendersScreen
                self.screenGeneration += 1
            }
        ))
    }

    /// A keystroke while a program runs. Returns false when no program has the keyboard.
    @discardableResult
    func sendKey(_ text: String) -> Bool {
        guard let program else { return false }
        program.input(text)
        return true
    }

    /// A special key (arrow, Home/End, F-key…) while a program runs. Encoded HERE because the
    /// arrows' form depends on DECCKM — a mode the screen owns, not the keyboard layer.
    @discardableResult
    func sendSpecialKey(_ key: TerminalKey, _ modifiers: TerminalKey.Modifiers) -> Bool {
        guard let program else { return false }
        program.input(key.encoded(modifiers, applicationCursor: screen.applicationCursorKeys))
        return true
    }

    /// Pasted text while a program runs. Wrapped in the bracketed-paste markers when the
    /// program asked for them (`ESC[?2004h`), so a multi-line paste is one block, not a burst
    /// of Enters. Returns false when no program has the keyboard (the field pastes normally).
    @discardableResult
    func sendPaste(_ text: String) -> Bool {
        guard let program else { return false }
        if screen.bracketedPaste {
            program.input("\u{1b}[200~" + text + "\u{1b}[201~")
        } else {
            program.input(text)
        }
        return true
    }

    /// The container's measured geometry; resizes the grid and tells the program (SIGWINCH).
    func setGridSize(rows: Int, columns: Int) {
        let rows = max(4, rows), columns = max(20, columns)
        guard rows != gridRows || columns != gridColumns else { return }
        gridRows = rows
        gridColumns = columns
        guard program != nil else { return }
        screen.resize(rows: rows, columns: columns)
        screenGeneration += 1
        program?.resize(rows: rows, columns: columns)
    }

    private func programExited() {
        guard program != nil else { return }
        // An inline TUI (ink — never on the alt screen) leaves its last frame on the normal
        // screen, and on a real terminal that frame stays in history when the prompt returns.
        // Ours does the same: the final grid rows join the scrollback. A scaffolder's closing
        // instructions ("cd app && npm install") survive the flip back. Alt-screen programs
        // restored the normal screen instead — nothing of theirs to keep, same as real less.
        if programOnScreen, !programUsedAltScreen {
            let rows = (0..<screen.rows).map { screen.text(row: $0) }
            if let last = rows.lastIndex(where: { !$0.isEmpty }) {
                for row in rows[...last] { append(row, .output) }
            }
        }
        program = nil
        programOnScreen = false
        interruptedAt = nil
        parser.respond = nil
        // A crashed-out program must not strand the terminal on the alt screen.
        if screen.isAlternate { parser.feed("\u{1b}[?25h\u{1b}[?1049l") }
        screenGeneration += 1
    }

    private func runShell(_ command: String, hooks: Hooks, screenless: Bool = false) {
        // No launcher means no screen to take: `runNode` sees `launchProgram == nil` and runs
        // the bin the way that RETURNS its output, which is what a caller without a grid can
        // actually use. Spelled out rather than inlined — a ternary over an optional closure
        // gives the type checker nothing to work with.
        var launcher: (@MainActor @Sendable (any TerminalProgram) -> Void)?
        if !screenless {
            launcher = { [weak self] program in self?.launch(program) ?? () }
        }
        let context = MouseShell.Context(
            root: root,
            markModified: { hooks.markModified($0) },
            openFile: { hooks.openFile($0) },
            clear: { [weak self] in self?.lines = [] },
            emit: { [weak self] output in
                self?.append(output.text, output.isError ? .error : .output)
            },
            reloadTree: { hooks.reloadTree() },
            historyChanged: { hooks.historyChanged() },
            githubToken: { hooks.githubToken() },
            githubLogin: { hooks.githubLogin() },
            launchProgram: launcher,
            // No grid means no program can take the screen — so its output flows here, as
            // it is produced, the way a terminal would have shown it.
            liveOutput: screenless
        )
        isRunning = true
        runningTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await self.shell.execute(command, context: context)
            if let echo = result.echoExpansion {
                self.append("\(self.prompt) \(echo)", .command)
            }
            for output in result.outputs {
                self.append(output.text, output.isError ? .error : .output)
            }
            self.isRunning = false
        }
    }

    private func runJavaScript(_ command: String) {
        for output in javascript.evaluate(command) {
            append(output.text, output.isError ? .error : .output)
        }
    }

    /// Surface something that happened OUTSIDE the prompt (a corner-slot action) in the
    /// scrollback. The terminal is the app's one honest error surface: a failure belongs in
    /// text you can read and scroll back to, not encoded in the color of a pill.
    func report(_ text: String, isError: Bool = true) {
        append(text, isError ? .error : .output)
    }

    private func append(_ text: String, _ kind: Line.Kind) {
        lines.append(Line(text: text, kind: kind))
        if lines.count > 500 { lines.removeFirst(lines.count - 500) }
    }
}

/// The `js` engine: a persistent JavaScriptCore context (state survives between lines, like a
/// browser console). `console.log` is captured into the scrollback; exceptions print as
/// errors; a statement's value prints unless it's undefined.
final class JSEngine {
    private let context = JSContext()!
    private var logged: [String] = []

    init() {
        let log: @convention(block) (String) -> Void = { [weak self] message in
            self?.logged.append(message)
        }
        context.setObject(log, forKeyedSubscript: "__mouseLog" as NSString)
        context.evaluateScript("""
            var console = { log: function() {
                __mouseLog(Array.prototype.map.call(arguments, String).join(' '));
            }};
            console.error = console.warn = console.info = console.log;
        """)
    }

    func evaluate(_ source: String) -> [(text: String, isError: Bool)] {
        logged = []
        var outputs: [(String, Bool)] = []
        context.exceptionHandler = { _, exception in
            outputs.append((exception?.toString() ?? "exception", true))
        }
        let result = context.evaluateScript(source)
        context.exceptionHandler = nil
        outputs.insert(contentsOf: logged.map { ($0, false) }, at: 0)
        if outputs.allSatisfy({ !$0.1 }), let result, !result.isUndefined {
            outputs.append((result.toString() ?? "", false))
        }
        return outputs.map { (text: $0.0, isError: $0.1) }
    }
}

/// The engine switcher: a small capsule in the terminal container's top-LEFT corner showing
/// the active engine's name; tapping cycles engines. The counterpart of the top-right action
/// chips, in the same drawn-not-symboled language.
