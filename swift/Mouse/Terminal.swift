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
    /// prompt. While set, the container renders `screen` instead of the scrollback and every
    /// keystroke routes to the program — the foreground-process model without fork/exec.
    private(set) var program: TerminalProgram?
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

    /// Returns false when the input was refused (a command is already running) so the prompt
    /// field can keep its text.
    @discardableResult
    func run(_ raw: String, workspace: Workspace?, deck: CarouselDeck?) -> Bool {
        guard !isRunning, program == nil else { return false }
        let command = raw.trimmingCharacters(in: .whitespaces)
        append("\(prompt) \(command)", .command)
        guard !command.isEmpty else { return true }
        switch engine {
        case .msh: runShell(command, workspace: workspace, deck: deck)
        case .js: runJavaScript(command)
        }
        return true
    }

    /// Interrupt a running command (any keypress triggers this). Prints the classic ^C
    /// immediately; the command's own cancellation cleanup (ping's statistics line) follows
    /// as it winds down.
    func interrupt() {
        if let program {
            // ^C is a keystroke to a program — it decides what to do (and the host stops it
            // when it has no SIGINT handler of its own).
            program.input("\u{3}")
            return
        }
        guard isRunning else { return }
        append("^C", .command)
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
        self.program = program
        screenGeneration += 1
        program.start(io: TerminalProgramIO(
            rows: gridRows,
            columns: gridColumns,
            write: { [weak self] text in
                guard let self else { return }
                self.parser.feed(text)
                self.screenGeneration += 1
            },
            exit: { [weak self] in self?.programExited() }
        ))
    }

    /// A keystroke while a program runs. Returns false when no program has the keyboard.
    @discardableResult
    func sendKey(_ text: String) -> Bool {
        guard let program else { return false }
        program.input(text)
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
        program = nil
        // A crashed-out program must not strand the terminal on the alt screen.
        if screen.isAlternate { parser.feed("\u{1b}[?25h\u{1b}[?1049l") }
        screenGeneration += 1
    }

    private func runShell(_ command: String, workspace: Workspace?, deck: CarouselDeck?) {
        let context = MouseShell.Context(
            root: root,
            markModified: { workspace?.markModified($0) },
            openFile: { deck?.openFile($0) },
            clear: { [weak self] in self?.lines = [] },
            emit: { [weak self] output in
                self?.append(output.text, output.isError ? .error : .output)
            },
            reloadTree: { workspace?.bumpTreeVersion() },
            historyChanged: { workspace?.localHistoryChanged() },
            githubToken: { GitHubAuth.shared.accessToken },
            githubLogin: {
                if case .signedIn(let login) = GitHubAuth.shared.phase { return login }
                return nil
            },
            launchProgram: { [weak self] program in self?.launch(program) }
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

struct TerminalContainerView: View {
    let deck: CarouselDeck?

    @State private var promptFocused = false

    var body: some View {
        Group {
            if let deck, let workspace = deck.workspace {
                // The ring's OWN session: rings sharing a repo get separate terminals.
                let terminal = deck.terminal(for: workspace)
                VStack(alignment: .leading, spacing: 6) {
                    // Two modes, like a real terminal: the transcript (scrollback), or the
                    // SCREEN while a full-screen program (less, top) owns it. The geometry
                    // reader sizes the character grid either way, so a program is born at
                    // the size it will draw into.
                    GeometryReader { geo in
                        Group {
                            if terminal.program?.rendersScreen == true {
                                TerminalScreenGrid(terminal: terminal)
                            } else {
                                // Bottom-anchored like a chat: content sticks to the bottom
                                // as output arrives, with no manual scrollTo to miscompute
                                // against unlaid-out lines (which used to park the response
                                // offscreen). Scrolling up to read holds.
                                ScrollView {
                                    LazyVStack(alignment: .leading, spacing: 2) {
                                        ForEach(terminal.lines) { line in
                                            Text(line.text)
                                                .font(.custom(AppFont.asciiName, size: 12))
                                                .foregroundStyle(color(for: line.kind))
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                    }
                                }
                                .defaultScrollAnchor(.bottom)
                            }
                        }
                        .onAppear { applyGrid(geo.size, terminal: terminal) }
                        .onChange(of: geo.size) { _, size in applyGrid(size, terminal: terminal) }
                    }
                    HStack(spacing: 6) {
                        // While a program runs, its name stands where the prompt was.
                        Text(terminal.program?.title ?? terminal.prompt)
                            .font(.custom(AppFont.asciiName, size: 12))
                            .opacity(0.7)
                        TerminalPromptField(
                            isFocused: $promptFocused,
                            onCommand: { command in
                                terminal.run(command, workspace: workspace, deck: deck)
                            },
                            onKey: { key in terminal.sendKey(key) },
                            onInterrupt: { terminal.interrupt() },
                            isBusy: { terminal.isRunning }
                        )
                        .frame(maxWidth: .infinity)
                        .frame(height: 22)
                    }
                }
                .padding(16)
                .contentShape(Rectangle())
                .onTapGesture { promptFocused = true }
            } else {
                Text("open a project in the Files container")
                    .font(.custom(AppFont.asciiName, size: 14))
                    .multilineTextAlignment(.center)
                    .opacity(0.6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .foregroundStyle(.white)
    }

    private func color(for kind: TerminalSession.Line.Kind) -> Color {
        switch kind {
        case .command: .white
        case .output: .white.opacity(0.8)
        case .error: .red
        }
    }

    private func applyGrid(_ size: CGSize, terminal: TerminalSession) {
        terminal.setGridSize(rows: Int(size.height / TerminalCellMetrics.height),
                             columns: Int(size.width / TerminalCellMetrics.width))
    }
}

/// The terminal's character-cell geometry, measured once from the mono font — the view and
/// the session must agree on how many cells fit.
enum TerminalCellMetrics {
    static let uiFont = UIFont(name: AppFont.asciiName, size: 12)
        ?? .monospacedSystemFont(ofSize: 12, weight: .regular)
    static let width: CGFloat = ("M" as NSString).size(withAttributes: [.font: uiFont]).width
    static let height: CGFloat = uiFont.lineHeight
}

/// The SCREEN renderer: rows of styled cells while a program owns the terminal. Redraws are
/// driven by `screenGeneration` (the grid itself is a Foundation engine, not observable).
/// No gestures of its own — the gesture law: content gets taps and the keyboard, the shell
/// keeps the drags.
private struct TerminalScreenGrid: View {
    let terminal: TerminalSession

    var body: some View {
        let _ = terminal.screenGeneration
        let screen = terminal.screen
        VStack(alignment: .leading, spacing: 0) {
            ForEach(0..<screen.rows, id: \.self) { row in
                Text(attributed(screen: screen, row: row))
                    .font(.custom(AppFont.asciiName, size: 12))
                    .lineLimit(1)
                    .frame(height: TerminalCellMetrics.height, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func attributed(screen: TerminalScreen, row: Int) -> AttributedString {
        var result = AttributedString()
        let showCursor = screen.cursorVisible && row == screen.cursorRow
        let cells = screen.grid[row]
        var index = 0
        while index < cells.count {
            var style = cells[index].style
            if showCursor && index == min(screen.cursorColumn, cells.count - 1) {
                style.inverse.toggle()
                var cell = AttributedString(String(cells[index].character))
                apply(style, to: &cell)
                result += cell
                index += 1
                continue
            }
            // Run-length batching: consecutive cells sharing a style render as one chunk.
            var text = ""
            let runStart = index
            while index < cells.count, cells[index].style == style,
                  !(showCursor && index == min(screen.cursorColumn, cells.count - 1)) {
                text.append(cells[index].character)
                index += 1
            }
            if index == runStart { index += 1; continue }
            var chunk = AttributedString(text)
            apply(style, to: &chunk)
            result += chunk
        }
        return result
    }

    private func apply(_ style: CellStyle, to text: inout AttributedString) {
        var foreground = color(style.foreground) ?? .white.opacity(0.9)
        var background = color(style.background)
        if style.inverse {
            let fg = foreground
            foreground = background ?? .black
            background = fg
        }
        if style.dim { foreground = foreground.opacity(0.55) }
        text.foregroundColor = foreground
        if let background { text.backgroundColor = background }
        if style.underline { text.underlineStyle = .single }
    }

    /// nil means "the terminal's own default" — white text on the container's black.
    private func color(_ ansi: AnsiColor) -> Color? {
        switch ansi {
        case .default:
            return nil
        case .rgb(let r, let g, let b):
            return Color(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
        case .indexed(let index):
            return Self.indexed(index)
        }
    }

    /// The xterm 256-color table: 16 named, a 6×6×6 cube, a 24-step gray ramp.
    private static func indexed(_ index: Int) -> Color {
        func rgb(_ r: Int, _ g: Int, _ b: Int) -> Color {
            Color(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
        }
        switch index {
        case 0: return rgb(0, 0, 0)
        case 1: return rgb(205, 49, 49)
        case 2: return rgb(13, 188, 121)
        case 3: return rgb(229, 229, 16)
        case 4: return rgb(36, 114, 200)
        case 5: return rgb(188, 63, 188)
        case 6: return rgb(17, 168, 205)
        case 7: return rgb(229, 229, 229)
        case 8: return rgb(102, 102, 102)
        case 9: return rgb(241, 76, 76)
        case 10: return rgb(35, 209, 139)
        case 11: return rgb(245, 245, 67)
        case 12: return rgb(59, 142, 234)
        case 13: return rgb(214, 112, 214)
        case 14: return rgb(41, 184, 219)
        case 15: return rgb(255, 255, 255)
        case 16...231:
            let value = index - 16
            let steps = [0, 95, 135, 175, 215, 255]
            return rgb(steps[value / 36], steps[(value / 6) % 6], steps[value % 6])
        case 232...255:
            let gray = 8 + (index - 232) * 10
            return rgb(gray, gray, gray)
        default:
            return .white
        }
    }
}


/// UIKit-backed prompt: pressing return runs the command WITHOUT resigning first responder
/// (returning `false` from `textFieldShouldReturn`), so the keyboard never dips between
/// commands — SwiftUI's TextField unavoidably dismisses on submit, which flickered it.
///
/// It also carries the interrupt: while a command is running, any keypress is swallowed and
/// routed to `onInterrupt` instead of being inserted — the phone's Ctrl-C. (New input is
/// refused during a run anyway, so a keystroke can only mean "stop".)
private struct TerminalPromptField: UIViewRepresentable {
    @Binding var isFocused: Bool
    /// Returns true if the command was accepted (clear the field) or false if refused (busy).
    let onCommand: (String) -> Bool
    /// A raw keystroke while a full-screen program has the keyboard. Returns true when a
    /// program consumed it (the key never reaches the field).
    let onKey: (String) -> Bool
    let onInterrupt: () -> Void
    let isBusy: () -> Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.delegate = context.coordinator
        field.font = UIFont(name: AppFont.asciiName, size: 12) ?? .monospacedSystemFont(ofSize: 12, weight: .bold)
        field.textColor = .white
        field.tintColor = .white
        field.backgroundColor = .clear
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.smartQuotesType = .no
        field.smartDashesType = .no
        field.spellCheckingType = .no
        field.keyboardType = .asciiCapable
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.parent = self
        if isFocused, !field.isFirstResponder {
            field.becomeFirstResponder()
        } else if !isFocused, field.isFirstResponder {
            field.resignFirstResponder()
        }
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: TerminalPromptField
        init(_ parent: TerminalPromptField) { self.parent = parent }

        func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
            // A full-screen program has the keyboard: keys go to it, not into the field.
            if !string.isEmpty, parent.onKey(string) {
                return false
            }
            // While a command runs, any keypress interrupts it (the phone's Ctrl-C). New input
            // is refused during a run anyway, so a keystroke can only mean "stop" — the key is
            // swallowed rather than typed.
            if !string.isEmpty, parent.isBusy() {
                parent.onInterrupt()
                return false
            }
            return true
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            // Return is a keystroke too while a program runs (the pager's "next line").
            if parent.onKey("\r") {
                return false
            }
            // Refused while busy (except the interrupt path above); keep the typed text.
            if parent.onCommand(textField.text ?? "") {
                textField.text = ""
            }
            return false  // keep first responder: the keyboard never leaves mid-session
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            DispatchQueue.main.async { self.parent.isFocused = true }
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            DispatchQueue.main.async { self.parent.isFocused = false }
        }
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
struct TerminalEngineChip: View {
    let session: TerminalSession
    let cornerRadius: CGFloat

    var body: some View {
        Button {
            session.switchEngine()
        } label: {
            Text(session.engine.rawValue)
                .font(.custom(AppFont.asciiName, size: 10))
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 8)
                .frame(height: 22)
                .overlay(Capsule().strokeBorder(.white.opacity(0.35), lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
