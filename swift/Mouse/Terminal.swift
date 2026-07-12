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
        append("[engine: \(engine == .msh ? "msh — mouse shell" : "js — JavaScriptCore")]", .output)
    }

    /// Returns false when the input was refused (a command is already running) so the prompt
    /// field can keep its text.
    @discardableResult
    func run(_ raw: String, workspace: Workspace?, deck: CarouselDeck?) -> Bool {
        guard !isRunning else { return false }
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
        guard isRunning else { return }
        append("^C", .command)
        runningTask?.cancel()
    }

    private func runShell(_ command: String, workspace: Workspace?, deck: CarouselDeck?) {
        let context = MouseShell.Context(
            root: root,
            markModified: { workspace?.markModified($0) },
            openFile: { deck?.openFile($0) },
            clear: { [weak self] in self?.lines = [] },
            emit: { [weak self] output in
                self?.append(output.text, output.isError ? .error : .output)
            }
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
                    // Bottom-anchored like a chat: content sticks to the bottom as output
                    // arrives, with no manual scrollTo to miscompute against unlaid-out lines
                    // (which used to park the response offscreen). Scrolling up to read holds.
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
                    HStack(spacing: 6) {
                        Text(terminal.prompt)
                            .font(.custom(AppFont.asciiName, size: 12))
                            .opacity(0.7)
                        TerminalPromptField(
                            isFocused: $promptFocused,
                            onCommand: { command in
                                terminal.run(command, workspace: workspace, deck: deck)
                            },
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
                Text("open a repo in the Files container —\nthe terminal runs on the workspace")
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
