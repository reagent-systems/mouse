import Foundation

/// A terminal SCREEN: the second thing a terminal can be.
///
/// The scrollback (`TerminalSession.lines`) is a transcript — an append-only list of what was
/// said. That's the right model for a shell, and the wrong one for `vim`, `htop`, or an agent
/// CLI with a live input line: those programs don't append, they *draw*, addressing a fixed grid
/// by row and column and repainting cells in place.
///
/// So a real terminal is two modes. Programs switch to this one with the alt-screen sequence
/// (`ESC [ ? 1049 h`), draw for as long as they run, and switch back — which is why `vim` leaves
/// your shell history undisturbed when it exits.
///
/// Foundation-only by design (no SwiftUI), so it verifies headlessly against a real terminal's
/// behavior per AGENTS.md. Colors are declared as data (`AnsiColor`); mapping them to something
/// drawable is the view layer's job.
///
/// Scope: the VT100/xterm subset real programs actually emit — cursor motion, erase, insert and
/// delete of lines and characters, scroll regions, SGR attributes, 256-color and truecolor. Not
/// implemented (and deliberately so): character sets, double-width lines, mouse reporting,
/// sixel graphics.

/// A color as ANSI expresses it. `.default` means "the terminal's own foreground/background",
/// which is what keeps an ordinary program monochrome inside Mouse's black container.
enum AnsiColor: Equatable, Sendable {
    case `default`
    /// 0–7 standard, 8–15 bright, 16–231 the 6×6×6 cube, 232–255 grayscale.
    case indexed(Int)
    case rgb(UInt8, UInt8, UInt8)
}

/// Everything SGR can say about one cell.
struct CellStyle: Equatable, Sendable {
    var foreground: AnsiColor = .default
    var background: AnsiColor = .default
    var bold = false
    var dim = false
    var italic = false
    var underline = false
    /// Swap foreground and background at draw time — how TUIs draw selections and status bars.
    var inverse = false

    static let plain = CellStyle()
}

struct TerminalCell: Equatable, Sendable {
    var character: Character = " "
    var style: CellStyle = .plain
    /// The right-hand column of a two-column character. It carries no glyph of its own — the
    /// wide character to its left is drawn across both — but it must occupy the cell so the
    /// grid's arithmetic stays honest.
    var isContinuation: Bool = false

    static let blank = TerminalCell()
}

/// The grid, the cursor, and the rules for moving both.
///
/// Coordinates are 0-based internally; ANSI is 1-based on the wire, and the parser converts.
/// Every mutation clamps to the grid, because a program that walks off the edge should be
/// pinned, not crash the app.
final class TerminalScreen {
    private(set) var rows: Int
    private(set) var columns: Int
    private(set) var grid: [[TerminalCell]]

    private(set) var cursorRow = 0
    private(set) var cursorColumn = 0
    var cursorVisible = true

    /// The current drawing attributes — SGR mutates this, and every printed cell copies it.
    var style: CellStyle = .plain

    /// The scrolling region (DECSTBM), inclusive. Scrolling and newlines act only inside it,
    /// which is how a TUI keeps a header or status bar pinned while content scrolls beneath.
    private var scrollTop = 0
    private var scrollBottom: Int

    private var savedCursor: (row: Int, column: Int, style: CellStyle)?

    /// Set once a program requests the alt screen; the view uses it to decide which of the two
    /// modes to render.
    private(set) var isAlternate = false

    /// DECCKM: while set (`ESC[?1h`), the arrow/Home/End keys encode as SS3 (`ESC O A`)
    /// instead of CSI (`ESC[A`). Readline and vim enable it and bind the application form —
    /// the keyboard layer reads this to encode arrows the way the running program expects.
    private(set) var applicationCursorKeys = false

    /// Bracketed paste (`ESC[?2004h`): while set, pasted text reaches the program wrapped in
    /// `ESC[200~` … `ESC[201~`, so a multi-line paste is one atomic block instead of a burst
    /// of Enters. Agent CLIs and editors enable it precisely so a pasted snippet doesn't
    /// submit line-by-line.
    private(set) var bracketedPaste = false

    /// True when anything changed since the last render — lets the view skip untouched frames.
    private(set) var isDirty = true

    init(rows: Int = 24, columns: Int = 80) {
        self.rows = max(1, rows)
        self.columns = max(1, columns)
        self.scrollBottom = self.rows - 1
        self.grid = Array(repeating: Array(repeating: TerminalCell.blank, count: self.columns),
                          count: self.rows)
    }

    func markClean() { isDirty = false }

    // MARK: - Geometry

    /// Re-fit to a new size. Content is preserved top-left; the cursor is clamped. (Real
    /// terminals reflow wrapped lines here; we don't, because on a phone the size changes on
    /// rotation and reflowing a TUI's own layout would corrupt it — the program will repaint.)
    func resize(rows newRows: Int, columns newColumns: Int) {
        let newRows = max(1, newRows), newColumns = max(1, newColumns)
        guard newRows != rows || newColumns != columns else { return }
        var fresh = Array(repeating: Array(repeating: TerminalCell.blank, count: newColumns),
                          count: newRows)
        for row in 0..<min(rows, newRows) {
            for column in 0..<min(columns, newColumns) {
                fresh[row][column] = grid[row][column]
            }
        }
        grid = fresh
        rows = newRows
        columns = newColumns
        scrollTop = 0
        scrollBottom = newRows - 1
        cursorRow = min(cursorRow, newRows - 1)
        cursorColumn = min(cursorColumn, newColumns - 1)
        isDirty = true
    }

    // MARK: - Alt screen

    func enterAlternate() {
        guard !isAlternate else { return }
        isAlternate = true
        clearAll()
        moveCursor(row: 0, column: 0)
        isDirty = true
    }

    func leaveAlternate() {
        guard isAlternate else { return }
        isAlternate = false
        clearAll()
        moveCursor(row: 0, column: 0)
        isDirty = true
    }

    func setApplicationCursorKeys(_ enabled: Bool) {
        applicationCursorKeys = enabled
    }

    func setBracketedPaste(_ enabled: Bool) {
        bracketedPaste = enabled
    }

    // MARK: - Cursor

    func moveCursor(row: Int, column: Int) {
        cursorRow = min(max(0, row), rows - 1)
        cursorColumn = min(max(0, column), columns - 1)
        isDirty = true
    }

    func moveCursor(deltaRow: Int = 0, deltaColumn: Int = 0) {
        moveCursor(row: cursorRow + deltaRow, column: cursorColumn + deltaColumn)
    }

    // CUU/CUD stop at the scroll-region margin — but only when the cursor starts inside the
    // region; from outside it, the screen edge is the limit (xterm).

    func cursorUp(_ count: Int) {
        let limit = cursorRow >= scrollTop ? scrollTop : 0
        cursorRow = max(cursorRow - max(1, count), limit)
        cursorColumn = min(cursorColumn, columns - 1)
        isDirty = true
    }

    func cursorDown(_ count: Int) {
        let limit = cursorRow <= scrollBottom ? scrollBottom : rows - 1
        cursorRow = min(cursorRow + max(1, count), limit)
        cursorColumn = min(cursorColumn, columns - 1)
        isDirty = true
    }

    func saveCursor() { savedCursor = (cursorRow, cursorColumn, style) }

    func restoreCursor() {
        guard let saved = savedCursor else { return }
        moveCursor(row: saved.row, column: saved.column)
        style = saved.style
    }

    func setScrollRegion(top: Int, bottom: Int) {
        let top = min(max(0, top), rows - 1)
        let bottom = min(max(0, bottom), rows - 1)
        guard top < bottom else { return }
        scrollTop = top
        scrollBottom = bottom
        // xterm homes to the absolute top-left on DECSTBM, not the region top.
        moveCursor(row: 0, column: 0)
    }

    func resetScrollRegion() {
        scrollTop = 0
        scrollBottom = rows - 1
    }

    // MARK: - Writing

    /// Print one character at the cursor, wrapping at the right edge.
    func put(_ character: Character) {
        let width = TerminalWidth.columns(of: character)
        // A zero-width character belongs to the grapheme already on the screen. Swift usually
        // merges it before it reaches here; when it arrives alone, attach it rather than letting
        // it consume a column.
        if width == 0 {
            let target = cursorColumn > 0 ? cursorColumn - 1 : 0
            if target < columns, !grid[cursorRow][target].isContinuation {
                // A Character is a whole grapheme cluster, so the mark is merged by rebuilding
                // the cluster from its text rather than mutated in place.
                let merged = String(grid[cursorRow][target].character) + String(character)
                if let combined = merged.first, merged.count == 1 {
                    grid[cursorRow][target].character = combined
                    isDirty = true
                }
            }
            return
        }
        if cursorColumn >= columns {
            cursorColumn = 0
            lineFeed()
        }
        // A two-column character cannot straddle the right edge: it wraps whole, as a real
        // terminal does, rather than being split across two lines.
        if width == 2, cursorColumn == columns - 1 {
            grid[cursorRow][cursorColumn] = TerminalCell(character: " ", style: style)
            cursorColumn = 0
            lineFeed()
        }
        clearWidePartner(row: cursorRow, column: cursorColumn)
        grid[cursorRow][cursorColumn] = TerminalCell(character: character, style: style)
        if width == 2, cursorColumn + 1 < columns {
            clearWidePartner(row: cursorRow, column: cursorColumn + 1)
            grid[cursorRow][cursorColumn + 1] = TerminalCell(character: " ", style: style,
                                                             isContinuation: true)
        }
        cursorColumn += width
        isDirty = true
    }

    /// Overwriting either half of a two-column character destroys the whole thing, so the other
    /// half has to go blank. Without this a grid accumulates orphans: a continuation cell with
    /// nothing to its left, or a wide glyph whose partner now holds someone else's letter.
    private func clearWidePartner(row: Int, column: Int) {
        guard row < grid.count, column < columns else { return }
        if grid[row][column].isContinuation {
            if column > 0 { grid[row][column - 1] = TerminalCell(style: grid[row][column - 1].style) }
        } else if column + 1 < columns, grid[row][column + 1].isContinuation {
            grid[row][column + 1] = TerminalCell(style: grid[row][column + 1].style)
        }
    }

    /// Down one row, scrolling the region when already at its bottom.
    func lineFeed() {
        if cursorRow == scrollBottom {
            scrollUp(1)
        } else if cursorRow < rows - 1 {
            cursorRow += 1
        }
        isDirty = true
    }

    /// Up one row, scrolling the region down when already at its top — the inverse of
    /// `lineFeed`, emitted as `ESC M` (how `less` scrolls backward).
    func reverseIndex() {
        if cursorRow == scrollTop {
            scrollDown(1)
        } else if cursorRow > 0 {
            cursorRow -= 1
        }
        isDirty = true
    }

    func carriageReturn() {
        cursorColumn = 0
        isDirty = true
    }

    func backspace() {
        if cursorColumn > 0 { cursorColumn -= 1 }
        isDirty = true
    }

    /// Advance to the next 8-column tab stop (the fixed default; DECTABSSTOPS isn't supported).
    func tab() {
        let next = ((cursorColumn / 8) + 1) * 8
        cursorColumn = min(next, columns - 1)
        isDirty = true
    }

    // MARK: - Scrolling

    func scrollUp(_ count: Int) {
        guard count > 0 else { return }
        for _ in 0..<count {
            grid.remove(at: scrollTop)
            grid.insert(Array(repeating: blankCell(), count: columns), at: scrollBottom)
        }
        isDirty = true
    }

    func scrollDown(_ count: Int) {
        guard count > 0 else { return }
        for _ in 0..<count {
            grid.remove(at: scrollBottom)
            grid.insert(Array(repeating: blankCell(), count: columns), at: scrollTop)
        }
        isDirty = true
    }

    // MARK: - Erasing

    /// A blank that carries the current BACKGROUND — erasing inside a colored region must leave
    /// the color behind, or TUIs get holes punched in their panels.
    private func blankCell() -> TerminalCell {
        var cell = TerminalCell.blank
        cell.style.background = style.background
        return cell
    }

    func clearAll() {
        grid = Array(repeating: Array(repeating: blankCell(), count: columns), count: rows)
        isDirty = true
    }

    /// ED: 0 = cursor to end of screen, 1 = start of screen to cursor, 2/3 = all.
    func eraseInDisplay(_ mode: Int) {
        switch mode {
        case 0:
            eraseInLine(0)
            if cursorRow + 1 < rows {
                for row in (cursorRow + 1)..<rows {
                    grid[row] = Array(repeating: blankCell(), count: columns)
                }
            }
        case 1:
            eraseInLine(1)
            if cursorRow > 0 {
                for row in 0..<cursorRow {
                    grid[row] = Array(repeating: blankCell(), count: columns)
                }
            }
        default:
            clearAll()
        }
        isDirty = true
    }

    /// EL: 0 = cursor to end of line, 1 = start of line to cursor, 2 = whole line.
    func eraseInLine(_ mode: Int) {
        switch mode {
        case 0:
            for column in cursorColumn..<columns { grid[cursorRow][column] = blankCell() }
        case 1:
            for column in 0...min(cursorColumn, columns - 1) { grid[cursorRow][column] = blankCell() }
        default:
            grid[cursorRow] = Array(repeating: blankCell(), count: columns)
        }
        isDirty = true
    }

    // MARK: - Insert / delete

    // IL and DL both home the cursor to the first column (VT510: "the cursor moves to the
    // first column of the line").

    func insertLines(_ count: Int) {
        guard cursorRow >= scrollTop, cursorRow <= scrollBottom else { return }
        for _ in 0..<max(0, count) {
            grid.remove(at: scrollBottom)
            grid.insert(Array(repeating: blankCell(), count: columns), at: cursorRow)
        }
        cursorColumn = 0
        isDirty = true
    }

    func deleteLines(_ count: Int) {
        guard cursorRow >= scrollTop, cursorRow <= scrollBottom else { return }
        for _ in 0..<max(0, count) {
            grid.remove(at: cursorRow)
            grid.insert(Array(repeating: blankCell(), count: columns), at: scrollBottom)
        }
        cursorColumn = 0
        isDirty = true
    }

    // After printing into the last column the cursor rests AT `columns` (pending wrap), so
    // every in-line edit clamps it back onto the grid first.

    func insertCharacters(_ count: Int) {
        let column = min(cursorColumn, columns - 1)
        for _ in 0..<max(0, count) {
            grid[cursorRow].removeLast()
            grid[cursorRow].insert(blankCell(), at: column)
        }
        isDirty = true
    }

    func deleteCharacters(_ count: Int) {
        let column = min(cursorColumn, columns - 1)
        for _ in 0..<max(0, count) {
            grid[cursorRow].remove(at: column)
            grid[cursorRow].append(blankCell())
        }
        isDirty = true
    }

    func eraseCharacters(_ count: Int) {
        let start = min(cursorColumn, columns - 1)
        let end = min(start + max(1, count), columns)
        for column in start..<end { grid[cursorRow][column] = blankCell() }
        isDirty = true
    }

    // MARK: - Reading (for the view and for tests)

    /// One row as plain text, trailing blanks trimmed.
    func text(row: Int) -> String {
        guard row >= 0, row < rows else { return "" }
        let line = String(grid[row].map(\.character))
        return String(line.reversed().drop { $0 == " " }.reversed())
    }

    /// The whole screen as plain text — the headless test's window into the grid.
    var plainText: String {
        (0..<rows).map { text(row: $0) }.joined(separator: "\n")
    }
}

/// Feeds text to a `TerminalScreen`, interpreting ANSI escape sequences.
///
/// A byte-at-a-time state machine, because escape sequences arrive split across reads: a program
/// can emit `ESC [` in one write and `2J` in the next, and a parser that assumed whole sequences
/// would corrupt the screen. State persists between `feed` calls for exactly that reason.
final class AnsiParser {
    private enum State {
        case ground
        case escape
        /// Inside `ESC [ … final`.
        case csi
        /// Inside `ESC ] … BEL/ST` (window title and friends — parsed, then discarded).
        case osc
        /// After `ESC O` (SS3): the single next byte is a cursor/function final.
        case ss3
    }

    private let screen: TerminalScreen
    private var state: State = .ground
    private var parameters = ""
    private var intermediates = ""
    private var oscBuffer = ""

    /// The reply path for terminal queries (DSR, DA, DECRQM): a real terminal answers on the
    /// program's stdin, so a TUI that probes cursor position or feature support gets its
    /// answer and proceeds instead of blocking. nil when no one is driving stdin (the pyte
    /// cross-check, static renders) — queries are then consumed silently, as before.
    var respond: ((String) -> Void)?

    init(screen: TerminalScreen) {
        self.screen = screen
    }

    /// Iterates unicode SCALARS, not Characters: Swift's grapheme segmentation fuses `\r\n`
    /// into one Character that matches neither control, silently eating every CRLF.
    func feed(_ text: String) {
        for scalar in text.unicodeScalars { feed(scalar) }
    }

    private func feed(_ scalar: Unicode.Scalar) {
        switch state {
        case .ground: ground(scalar)
        case .escape: escape(scalar)
        case .csi: csi(scalar)
        case .osc: osc(scalar)
        case .ss3: ss3(scalar)
        }
    }

    private func ground(_ scalar: Unicode.Scalar) {
        switch scalar {
        case "\u{1b}":
            state = .escape
            parameters = ""
            intermediates = ""
        case "\n": screen.lineFeed()
        case "\r": screen.carriageReturn()
        case "\t": screen.tab()
        case "\u{8}": screen.backspace()
        case "\u{7}": break            // bell: a phone shouldn't beep at you
        default:
            // Skip other C0 controls; print everything else (including full Unicode).
            if scalar.value < 0x20 { return }
            screen.put(Character(scalar))
        }
    }

    private func escape(_ scalar: Unicode.Scalar) {
        switch scalar {
        case "[":
            state = .csi
            parameters = ""
            intermediates = ""
        case "]":
            state = .osc
            oscBuffer = ""
        case "7":
            screen.saveCursor(); state = .ground
        case "8":
            screen.restoreCursor(); state = .ground
        case "O":
            state = .ss3   // SS3 — the application-cursor-key form (ESC O A/B/C/D/H/F)
        case "M":
            screen.reverseIndex(); state = .ground
        case "c":
            screen.clearAll(); screen.moveCursor(row: 0, column: 0)
            screen.style = .plain; screen.resetScrollRegion(); state = .ground
        case "(", ")", "#", "%":
            // Character-set selects: consume this and the next byte, ignore both.
            intermediates = String(Character(scalar)); state = .escape
        default:
            state = .ground
        }
    }

    /// SS3: one final byte after `ESC O`. The cursor/Home/End forms move the cursor exactly
    /// like their CSI twins, so a program that draws in application-cursor mode positions the
    /// same. Function-key finals (P–S) carry no screen action.
    private func ss3(_ scalar: Unicode.Scalar) {
        defer { state = .ground }
        switch scalar {
        case "A": screen.cursorUp(1)
        case "B": screen.cursorDown(1)
        case "C": screen.moveCursor(deltaColumn: 1)
        case "D": screen.moveCursor(deltaColumn: -1)
        case "H": screen.moveCursor(row: 0, column: 0)
        case "F": screen.moveCursor(row: screen.cursorRow, column: screen.columns - 1)
        default: break
        }
    }

    private func csi(_ scalar: Unicode.Scalar) {
        // Parameter bytes (digits, ';', and private markers like '?') accumulate.
        if ("0"..."9").contains(scalar) || scalar == ";" || scalar == "?" || scalar == ">" || scalar == "=" {
            parameters.unicodeScalars.append(scalar)
            return
        }
        if scalar == " " || scalar == "!" || scalar == "\"" || scalar == "$" || scalar == "'" {
            intermediates.unicodeScalars.append(scalar)
            return
        }
        defer { state = .ground; parameters = ""; intermediates = "" }
        dispatchCSI(final: Character(scalar))
    }

    private func osc(_ scalar: Unicode.Scalar) {
        // Terminated by BEL, or by ST (`ESC \`) — the ESC is swallowed here and the backslash
        // ends it on the next byte.
        if scalar == "\u{7}" {
            state = .ground
            oscBuffer = ""
            return
        }
        if scalar == "\u{1b}" { return }
        if scalar == "\\" {
            state = .ground
            oscBuffer = ""
            return
        }
        oscBuffer.unicodeScalars.append(scalar)
    }

    // MARK: - CSI dispatch

    private var numericParameters: [Int] {
        parameters
            .drop { $0 == "?" || $0 == ">" || $0 == "=" }
            .split(separator: ";", omittingEmptySubsequences: false)
            .map { Int($0) ?? 0 }
    }

    private func parameter(_ index: Int, default fallback: Int) -> Int {
        let values = numericParameters
        guard index < values.count else { return fallback }
        // An omitted parameter means "use the default", and ANSI writes omitted as empty or 0.
        return values[index] == 0 ? fallback : values[index]
    }

    private func dispatchCSI(final: Character) {
        let isPrivate = parameters.hasPrefix("?")
        switch final {
        case "A": screen.cursorUp(parameter(0, default: 1))
        case "B": screen.cursorDown(parameter(0, default: 1))
        case "C": screen.moveCursor(deltaColumn: parameter(0, default: 1))
        case "D": screen.moveCursor(deltaColumn: -parameter(0, default: 1))
        case "E": screen.cursorDown(parameter(0, default: 1)); screen.carriageReturn()
        case "F": screen.cursorUp(parameter(0, default: 1)); screen.carriageReturn()
        case "G": screen.moveCursor(row: screen.cursorRow, column: parameter(0, default: 1) - 1)
        case "H", "f":
            screen.moveCursor(row: parameter(0, default: 1) - 1, column: parameter(1, default: 1) - 1)
        case "J": screen.eraseInDisplay(numericParameters.first ?? 0)
        case "K": screen.eraseInLine(numericParameters.first ?? 0)
        case "L": screen.insertLines(parameter(0, default: 1))
        case "M": screen.deleteLines(parameter(0, default: 1))
        case "P": screen.deleteCharacters(parameter(0, default: 1))
        case "X": screen.eraseCharacters(parameter(0, default: 1))
        case "@": screen.insertCharacters(parameter(0, default: 1))
        case "S": screen.scrollUp(parameter(0, default: 1))
        case "T": screen.scrollDown(parameter(0, default: 1))
        case "d": screen.moveCursor(row: parameter(0, default: 1) - 1, column: screen.cursorColumn)
        case "r":
            let values = numericParameters
            if values.count >= 2, values[0] > 0, values[1] > 0 {
                screen.setScrollRegion(top: values[0] - 1, bottom: values[1] - 1)
            } else {
                screen.resetScrollRegion()
            }
        case "s": screen.saveCursor()
        case "u": screen.restoreCursor()
        case "m": applySGR()
        case "h" where isPrivate: setMode(numericParameters, enabled: true)
        case "l" where isPrivate: setMode(numericParameters, enabled: false)
        case "n": deviceStatusReport(isPrivate: isPrivate)
        case "c": deviceAttributes(isPrivate: isPrivate)
        case "p" where intermediates.contains("$"): reportMode()
        default: break   // unimplemented sequences are consumed, never printed as garbage
        }
    }

    /// DSR — the program asks the terminal's status. `ESC[5n` → OK, `ESC[6n` → the cursor's
    /// 1-based position. The reply travels back on stdin, like a real tty.
    private func deviceStatusReport(isPrivate: Bool) {
        guard let respond else { return }
        switch numericParameters.first ?? 0 {
        case 5: respond("\u{1b}[0n")
        case 6: respond("\u{1b}[\(screen.cursorRow + 1);\(screen.cursorColumn + 1)R")
        default: break
        }
    }

    /// DA — "what are you?" Primary (`ESC[c`) answers a VT102 with no options; secondary
    /// (`ESC[>c`) answers a terminal-type/version triple. Enough for the feature checks
    /// modern CLIs run before enabling colour or the alt screen.
    private func deviceAttributes(isPrivate: Bool) {
        guard let respond else { return }
        if parameters.hasPrefix(">") {
            respond("\u{1b}[>0;10;0c")   // "VT220-ish", version 10 — matches xterm's shape
        } else {
            respond("\u{1b}[?6c")        // VT102
        }
    }

    /// DECRQM — "is mode N set?" `ESC[?<n>$p` → `ESC[?<n>;<state>$y`, where state 1=set,
    /// 2=reset. TUIs query synchronized output (2026) and bracketed paste (2004) this way to
    /// decide whether to use them; answering "reset but recognized" (2) is the honest reply.
    private func reportMode() {
        guard let respond else { return }
        guard let mode = numericParameters.first else { return }
        let state: Int
        switch mode {
        case 1: state = screen.applicationCursorKeys ? 1 : 2
        case 25: state = screen.cursorVisible ? 1 : 2
        case 1049, 47, 1047: state = screen.isAlternate ? 1 : 2
        case 2004: state = screen.bracketedPaste ? 1 : 2
        case 2026: state = 2   // synchronized output: recognized, never persistently set
        default: state = 0           // not recognized
        }
        respond("\u{1b}[?\(mode);\(state)$y")
    }

    private func setMode(_ modes: [Int], enabled: Bool) {
        for mode in modes {
            switch mode {
            case 1: screen.setApplicationCursorKeys(enabled)   // DECCKM
            case 25: screen.cursorVisible = enabled
            case 2004: screen.setBracketedPaste(enabled)
            case 1049, 47, 1047:
                enabled ? screen.enterAlternate() : screen.leaveAlternate()
            default: break   // mouse reporting, focus events, etc: accepted and ignored
            }
        }
    }

    private func applySGR() {
        let values = numericParameters.isEmpty ? [0] : numericParameters
        var index = 0
        while index < values.count {
            let code = values[index]
            switch code {
            case 0: screen.style = .plain
            case 1: screen.style.bold = true
            case 2: screen.style.dim = true
            case 3: screen.style.italic = true
            case 4: screen.style.underline = true
            case 7: screen.style.inverse = true
            case 22: screen.style.bold = false; screen.style.dim = false
            case 23: screen.style.italic = false
            case 24: screen.style.underline = false
            case 27: screen.style.inverse = false
            case 30...37: screen.style.foreground = .indexed(code - 30)
            case 39: screen.style.foreground = .default
            case 40...47: screen.style.background = .indexed(code - 40)
            case 49: screen.style.background = .default
            case 90...97: screen.style.foreground = .indexed(code - 90 + 8)
            case 100...107: screen.style.background = .indexed(code - 100 + 8)
            case 38, 48:
                // Extended color: `38;5;n` (indexed) or `38;2;r;g;b` (truecolor).
                guard index + 1 < values.count else { index = values.count; break }
                let isForeground = code == 38
                let kind = values[index + 1]
                if kind == 5, index + 2 < values.count {
                    let color = AnsiColor.indexed(values[index + 2])
                    if isForeground { screen.style.foreground = color } else { screen.style.background = color }
                    index += 2
                } else if kind == 2, index + 4 < values.count {
                    let color = AnsiColor.rgb(UInt8(clamping: values[index + 2]),
                                              UInt8(clamping: values[index + 3]),
                                              UInt8(clamping: values[index + 4]))
                    if isForeground { screen.style.foreground = color } else { screen.style.background = color }
                    index += 4
                } else {
                    index = values.count
                }
            default: break
            }
            index += 1
        }
    }
}
