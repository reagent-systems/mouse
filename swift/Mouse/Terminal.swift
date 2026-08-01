import SwiftUI
import JavaScriptCore

// The terminal's VIEWS. Its logic lives in TerminalSession.swift, which builds without a
// screen so the suite can drive it.
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
                            // Keyed on the session's OBSERVABLE flag, never on
                            // `program?.rendersScreen`: that property flips mid-run on a
                            // plain object, observation never fires, and the view keeps
                            // showing the scrollback while the TUI draws on an invisible
                            // grid (the claude-code-drew-in-the-scrollback bug).
                            if terminal.programOnScreen {
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
                                terminal.run(command, hooks: .init(
                                    markModified: { workspace.markModified($0) },
                                    openFile: { deck.openFile($0) },
                                    reloadTree: { workspace.bumpTreeVersion() },
                                    historyChanged: { workspace.localHistoryChanged() },
                                    githubToken: { GitHubAuth.shared.accessToken },
                                    githubLogin: {
                                        if case .signedIn(let login) = GitHubAuth.shared.phase { return login }
                                        return nil
                                    }))
                            },
                            onKey: { key in terminal.sendKey(key) },
                            onSpecialKey: { key, modifiers in terminal.sendSpecialKey(key, modifiers) },
                            onPaste: { text in terminal.sendPaste(text) },
                            onInterrupt: { terminal.interrupt() },
                            isBusy: { terminal.isRunning }
                        )
                        .frame(maxWidth: .infinity)
                        .frame(height: 22)
                        // While a PROGRAM owns the keyboard every keystroke belongs to it, so
                        // the any-key interrupt below it can never fire — and an iOS keyboard
                        // has no Control. Without this, a `node` server started here holds the
                        // terminal until the app is killed. Measured on the phone: three real
                        // HTTP requests answered, and no way back to a prompt.
                        if terminal.program != nil {
                            TerminalInterruptChip(session: terminal)
                        }
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
                var cell = AttributedString(cells[index].isContinuation ? ""
                                            : String(cells[index].character))
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
                // A continuation cell has no glyph: the wide character to its left is drawn
                // across both columns, so appending its placeholder would double the spacing.
                if !cells[index].isContinuation { text.append(cells[index].character) }
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
    /// A special key (arrow, Home/End, F-key…), encoded by the terminal so DECCKM is honored.
    let onSpecialKey: (TerminalKey, TerminalKey.Modifiers) -> Bool
    /// Pasted text; the terminal brackets it when the program enabled bracketed paste.
    let onPaste: (String) -> Bool
    let onInterrupt: () -> Void
    let isBusy: () -> Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextField {
        let field = ProgramKeyTextField()
        field.onSpecialKey = { [weak coordinator = context.coordinator] key, modifiers in
            coordinator?.parent.onSpecialKey(key, modifiers) ?? false
        }
        field.onControlBytes = { [weak coordinator = context.coordinator] bytes in
            coordinator?.parent.onKey(bytes) ?? false
        }
        field.onPaste = { [weak coordinator = context.coordinator] text in
            coordinator?.parent.onPaste(text) ?? false
        }
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
            // Backspace on the soft keyboard is an empty replacement over a one-char range.
            // A program reads it as DEL (0x7f), the way every terminal encodes Backspace.
            if string.isEmpty, range.length > 0, parent.onKey(TerminalKey.backspace.encoded()) {
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

/// A `UITextField` that hands hardware special keys (arrows, Home/End, Page keys, F-keys,
/// Tab, Escape, Ctrl-combos) to a running program as terminal escape sequences. Ordinary
/// characters and Return still flow through the delegate; only keys the field would otherwise
/// swallow or ignore are intercepted, and only while a program actually consumes them.
private final class ProgramKeyTextField: UITextField {
    /// Given the encoded bytes for a special key, returns true when a program took it (the
    /// field must not also edit itself). nil bytes mean "not a special key" — leave it to the
    /// field, whose delegate routes ordinary characters to the program.
    var onSpecialKey: ((TerminalKey, TerminalKey.Modifiers) -> Bool)?
    /// Ctrl-combos produce a bare control byte (no `TerminalKey` case) — this carries them.
    var onControlBytes: ((String) -> Bool)?
    /// A paste while a program has the keyboard — the whole pasteboard text as one delivery,
    /// so the terminal can bracket it. Returns true when the program took it.
    var onPaste: ((String) -> Bool)?

    override func paste(_ sender: Any?) {
        if let text = UIPasteboard.general.string, onPaste?(text) == true { return }
        super.paste(sender)   // no program: paste into the prompt field as normal
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            guard let key = press.key else { continue }
            var modifiers: TerminalKey.Modifiers = []
            if key.modifierFlags.contains(.shift) { modifiers.insert(.shift) }
            if key.modifierFlags.contains(.alternate) { modifiers.insert(.alt) }
            if key.modifierFlags.contains(.control) { modifiers.insert(.ctrl) }

            if let named = Self.named(key.keyCode, shift: modifiers.contains(.shift)) {
                if onSpecialKey?(named, modifiers) == true { return }
            } else if modifiers.contains(.ctrl),
                      let character = key.charactersIgnoringModifiers.first,
                      let bytes = TerminalKey.control(for: character) {
                if onControlBytes?(bytes) == true { return }
            }
        }
        super.pressesBegan(presses, with: event)
    }

    /// A hardware key code → a named `TerminalKey`, or nil for ordinary text keys (which the
    /// field types normally and the delegate forwards).
    private static func named(_ code: UIKeyboardHIDUsage, shift: Bool) -> TerminalKey? {
        switch code {
        case .keyboardUpArrow: return .up
        case .keyboardDownArrow: return .down
        case .keyboardRightArrow: return .right
        case .keyboardLeftArrow: return .left
        case .keyboardHome: return .home
        case .keyboardEnd: return .end
        case .keyboardPageUp: return .pageUp
        case .keyboardPageDown: return .pageDown
        case .keyboardInsert: return .insert
        case .keyboardDeleteForward: return .delete
        case .keyboardDeleteOrBackspace: return .backspace
        case .keyboardTab: return shift ? .backTab : .tab
        case .keyboardEscape: return .escape
        case .keyboardF1: return .function(1)
        case .keyboardF2: return .function(2)
        case .keyboardF3: return .function(3)
        case .keyboardF4: return .function(4)
        case .keyboardF5: return .function(5)
        case .keyboardF6: return .function(6)
        case .keyboardF7: return .function(7)
        case .keyboardF8: return .function(8)
        case .keyboardF9: return .function(9)
        case .keyboardF10: return .function(10)
        case .keyboardF11: return .function(11)
        case .keyboardF12: return .function(12)
        default: return nil
        }
    }
}

/// The stop control, shown only while a full-screen program holds the terminal. Named `^C`
/// because that is what it sends and what a terminal calls it — the program decides what
/// quitting means, exactly as it would on a machine with a Control key.
private struct TerminalInterruptChip: View {
    let session: TerminalSession

    var body: some View {
        Button {
            session.interrupt()
        } label: {
            Text("^C")
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
