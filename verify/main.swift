import Foundation

// Headless verification of TerminalScreen + AnsiParser per AGENTS.md.
// Mode 1 (no args): assertion corpus against xterm semantics.
// Mode 2 (`render <file> [rows] [cols]`): feed a raw escape stream, print plainText —
//         used to diff against pyte (a known-good emulator) for the same stream.

var failures = 0
func check(_ condition: Bool, _ label: String) {
    if !condition { failures += 1; print("FAIL: \(label)") }
}
func checkEqual(_ got: String, _ want: String, _ label: String) {
    if got != want {
        failures += 1
        print("FAIL: \(label)\n  got:  \(got.replacingOccurrences(of: "\n", with: "\\n"))\n  want: \(want.replacingOccurrences(of: "\n", with: "\\n"))")
    }
}

let arguments = CommandLine.arguments
if arguments.count >= 2, arguments[1] == "render" {
    let data = try! Data(contentsOf: URL(fileURLWithPath: arguments[2]))
    let rows = arguments.count > 3 ? Int(arguments[3])! : 24
    let cols = arguments.count > 4 ? Int(arguments[4])! : 80
    let screen = TerminalScreen(rows: rows, columns: cols)
    let parser = AnsiParser(screen: screen)
    parser.feed(String(decoding: data, as: UTF8.self))
    print(screen.plainText)
    exit(0)
}

func fresh(rows: Int = 24, cols: Int = 80) -> (TerminalScreen, AnsiParser) {
    let screen = TerminalScreen(rows: rows, columns: cols)
    return (screen, AnsiParser(screen: screen))
}

// -- plain text, CR, LF ------------------------------------------------------
do {
    let (s, p) = fresh(rows: 3, cols: 10)
    p.feed("hi\r\nworld")
    checkEqual(s.text(row: 0), "hi", "plain row 0")
    checkEqual(s.text(row: 1), "world", "plain row 1")
    check(s.cursorRow == 1 && s.cursorColumn == 5, "cursor after text")
    p.feed("\rX")
    checkEqual(s.text(row: 1), "Xorld", "CR overprints")
}

// -- wrap at right edge ------------------------------------------------------
do {
    let (s, p) = fresh(rows: 3, cols: 5)
    p.feed("abcdefg")
    checkEqual(s.text(row: 0), "abcde", "wrap row 0")
    checkEqual(s.text(row: 1), "fg", "wrap row 1")
}

// -- wrap at bottom scrolls --------------------------------------------------
do {
    let (s, p) = fresh(rows: 2, cols: 3)
    p.feed("abcdefghi")   // 3 full rows into 2 → first scrolls off
    checkEqual(s.text(row: 0), "def", "scroll on wrap row 0")
    checkEqual(s.text(row: 1), "ghi", "scroll on wrap row 1")
}

// -- CUP / cursor moves ------------------------------------------------------
do {
    let (s, p) = fresh()
    p.feed("\u{1b}[10;5H")
    check(s.cursorRow == 9 && s.cursorColumn == 4, "CUP 1-based → 0-based")
    p.feed("\u{1b}[H")
    check(s.cursorRow == 0 && s.cursorColumn == 0, "CUP default home")
    p.feed("\u{1b}[5B\u{1b}[3C")
    check(s.cursorRow == 5 && s.cursorColumn == 3, "CUD+CUF")
    p.feed("\u{1b}[A\u{1b}[D")
    check(s.cursorRow == 4 && s.cursorColumn == 2, "CUU+CUB default 1")
    p.feed("\u{1b}[99A")
    check(s.cursorRow == 0, "CUU clamps at top")
    p.feed("\u{1b}[999;999H")
    check(s.cursorRow == 23 && s.cursorColumn == 79, "CUP clamps bottom-right")
    p.feed("\u{1b}[7G")
    check(s.cursorColumn == 6, "CHA")
    p.feed("\u{1b}[12d")
    check(s.cursorRow == 11 && s.cursorColumn == 6, "VPA keeps column")
}

// -- ED / EL -----------------------------------------------------------------
do {
    let (s, p) = fresh(rows: 3, cols: 6)
    p.feed("aaaaaa\r\nbbbbbb\r\ncccccc")
    p.feed("\u{1b}[2;3H\u{1b}[0K")           // EL to end on row 1
    checkEqual(s.text(row: 1), "bb", "EL 0")
    p.feed("\u{1b}[3;3H\u{1b}[1K")           // EL to start on row 2
    checkEqual(s.text(row: 2), "   ccc", "EL 1 (inclusive)")
    p.feed("\u{1b}[2K")
    checkEqual(s.text(row: 2), "", "EL 2")
    let (s2, p2) = fresh(rows: 3, cols: 6)
    p2.feed("aaaaaa\r\nbbbbbb\r\ncccccc\u{1b}[2;3H\u{1b}[J")
    checkEqual(s2.text(row: 0), "aaaaaa", "ED 0 keeps above")
    checkEqual(s2.text(row: 1), "bb", "ED 0 trims cursor row")
    checkEqual(s2.text(row: 2), "", "ED 0 clears below")
    let (s3, p3) = fresh(rows: 3, cols: 6)
    p3.feed("aaaaaa\r\nbbbbbb\r\ncccccc\u{1b}[2;3H\u{1b}[1J")
    checkEqual(s3.text(row: 0), "", "ED 1 clears above")
    checkEqual(s3.text(row: 1), "   bbb", "ED 1 trims to cursor (inclusive)")
    checkEqual(s3.text(row: 2), "cccccc", "ED 1 keeps below")
    p3.feed("\u{1b}[2J")
    check(s3.plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "ED 2 clears all")
}

// -- scroll region -----------------------------------------------------------
do {
    let (s, p) = fresh(rows: 5, cols: 3)
    p.feed("aaa\r\nbbb\r\nccc\r\nddd\r\neee")
    p.feed("\u{1b}[2;4r")                     // region rows 1..3 (0-based)
    check(s.cursorRow == 0 && s.cursorColumn == 0, "DECSTBM homes to absolute top-left")
    p.feed("\u{1b}[4;3H\n")                   // LF at region bottom scrolls region only
    checkEqual(s.text(row: 0), "aaa", "region scroll keeps header")
    checkEqual(s.text(row: 1), "ccc", "region scrolled up")
    checkEqual(s.text(row: 2), "ddd", "region scrolled up 2")
    checkEqual(s.text(row: 3), "", "region bottom blank")
    checkEqual(s.text(row: 4), "eee", "region scroll keeps footer")
    p.feed("\u{1b}[r\u{1b}[5;3H\n")           // reset region; LF at screen bottom scrolls all
    checkEqual(s.text(row: 0), "ccc", "full scroll after reset")
}

// -- IL / DL inside region ---------------------------------------------------
do {
    let (s, p) = fresh(rows: 4, cols: 3)
    p.feed("aaa\r\nbbb\r\nccc\r\nddd")
    p.feed("\u{1b}[2;3r\u{1b}[2;1H\u{1b}[L")  // insert line at row 1 inside region 1..2
    checkEqual(s.text(row: 1), "", "IL blank at cursor")
    checkEqual(s.text(row: 2), "bbb", "IL pushed down")
    checkEqual(s.text(row: 3), "ddd", "IL respects region bottom")
    p.feed("\u{1b}[M")
    checkEqual(s.text(row: 1), "bbb", "DL pulls up")
}

// -- ICH / DCH / ECH ---------------------------------------------------------
do {
    let (s, p) = fresh(rows: 2, cols: 6)
    p.feed("abcdef\u{1b}[1;3H\u{1b}[2@")
    checkEqual(s.text(row: 0), "ab  cd", "ICH shifts right, drops end")
    p.feed("\u{1b}[2P")
    checkEqual(s.text(row: 0), "abcd", "DCH deletes at cursor")
    p.feed("\u{1b}[1;1H\u{1b}[2X")
    checkEqual(s.text(row: 0), "  cd", "ECH blanks without shifting")
}

// -- SGR ---------------------------------------------------------------------
do {
    let (s, p) = fresh()
    p.feed("\u{1b}[31mA")
    check(s.grid[0][0].style.foreground == .indexed(1), "SGR 31 red")
    p.feed("\u{1b}[1;44mB")
    check(s.grid[0][1].style.bold && s.grid[0][1].style.background == .indexed(4), "SGR 1;44")
    check(s.grid[0][1].style.foreground == .indexed(1), "SGR accumulates fg")
    p.feed("\u{1b}[0mC")
    check(s.grid[0][2].style == .plain, "SGR 0 reset")
    p.feed("\u{1b}[38;5;196mD")
    check(s.grid[0][3].style.foreground == .indexed(196), "SGR 256-color")
    p.feed("\u{1b}[48;2;10;20;30mE")
    check(s.grid[0][4].style.background == .rgb(10, 20, 30), "SGR truecolor bg")
    p.feed("\u{1b}[0;93mF")
    check(s.grid[0][5].style.foreground == .indexed(11), "SGR bright fg")
    p.feed("\u{1b}[7mG")
    check(s.grid[0][6].style.inverse, "SGR inverse")
    p.feed("\u{1b}[27;39;49mH")
    check(s.grid[0][7].style == CellStyle(bold: false), "SGR resets to default fg/bg")
    p.feed("\u{1b}[mI")
    check(s.grid[0][8].style == .plain, "SGR empty = reset")
}

// -- erase carries background (the TUI panel rule) ---------------------------
do {
    let (s, p) = fresh(rows: 2, cols: 4)
    p.feed("\u{1b}[44m\u{1b}[2J")
    check(s.grid[1][3].style.background == .indexed(4), "ED paints background")
    check(s.grid[1][3].character == " ", "ED blanks characters")
}

// -- alt screen --------------------------------------------------------------
do {
    let (s, p) = fresh(rows: 2, cols: 5)
    p.feed("shell")
    p.feed("\u{1b}[?1049h")
    check(s.isAlternate, "alt screen entered")
    checkEqual(s.plainText, "\n", "alt screen starts clear")
    check(s.cursorRow == 0 && s.cursorColumn == 0, "alt screen homes")
    p.feed("vim!!")
    p.feed("\u{1b}[?1049l")
    check(!s.isAlternate, "alt screen left")
    // 47 / 1047 too
    p.feed("\u{1b}[?47h")
    check(s.isAlternate, "mode 47 enters alt")
    p.feed("\u{1b}[?1047l")
    check(!s.isAlternate, "mode 1047 leaves alt")
}

// -- cursor visibility, save/restore -----------------------------------------
do {
    let (s, p) = fresh()
    p.feed("\u{1b}[?25l")
    check(!s.cursorVisible, "DECTCEM hide")
    p.feed("\u{1b}[?25h")
    check(s.cursorVisible, "DECTCEM show")
    p.feed("\u{1b}[5;5H\u{1b}[31m\u{1b}7\u{1b}[H\u{1b}[0m\u{1b}8")
    check(s.cursorRow == 4 && s.cursorColumn == 4, "DECRC position")
    check(s.style.foreground == .indexed(1), "DECRC restores style")
    p.feed("\u{1b}[10;10H\u{1b}[s\u{1b}[H\u{1b}[u")
    check(s.cursorRow == 9 && s.cursorColumn == 9, "CSI s/u")
}

// -- split sequences across feeds --------------------------------------------
do {
    let (s, p) = fresh()
    p.feed("\u{1b}")
    p.feed("[")
    p.feed("3")
    p.feed("1")
    p.feed("m")
    p.feed("\u{1b}[2;")
    p.feed("2H")
    p.feed("X")
    check(s.grid[1][1].character == "X" && s.grid[1][1].style.foreground == .indexed(1),
          "split sequence survives feed boundaries")
}

// -- OSC swallowed (BEL and ST terminators) ----------------------------------
do {
    let (s, p) = fresh()
    p.feed("\u{1b}]0;my title\u{7}after")
    checkEqual(s.text(row: 0), "after", "OSC BEL swallowed")
    let (s2, p2) = fresh()
    p2.feed("\u{1b}]2;title\u{1b}\\after")
    checkEqual(s2.text(row: 0), "after", "OSC ST swallowed")
}

// -- tabs, backspace, bell ---------------------------------------------------
do {
    let (s, p) = fresh(rows: 2, cols: 20)
    p.feed("ab\tX")
    check(s.grid[0][8].character == "X", "tab to next 8-stop")
    p.feed("\u{8}\u{8}Y")
    check(s.grid[0][7].character == "Y", "backspace moves left")
    p.feed("\u{7}")   // bell: no crash, no output
    let (s2, p2) = fresh(rows: 2, cols: 4)
    p2.feed("\u{8}Z")
    check(s2.grid[0][0].character == "Z", "backspace clamps at col 0")
}

// -- RIS ----------------------------------------------------------------------
do {
    let (s, p) = fresh(rows: 2, cols: 4)
    p.feed("\u{1b}[31mab\u{1b}c")
    check(s.plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "RIS clears")
    check(s.style == .plain, "RIS resets style")
    check(s.cursorRow == 0 && s.cursorColumn == 0, "RIS homes")
}

// -- reverse index at top of region scrolls down ------------------------------
do {
    let (s, p) = fresh(rows: 3, cols: 3)
    p.feed("aaa\r\nbbb\r\nccc\u{1b}[1;1H\u{1b}M")
    // xterm: RI at absolute top inserts a blank line, pushing content down
    checkEqual(s.text(row: 0), "", "RI at top scrolls down (blank)")
    checkEqual(s.text(row: 1), "aaa", "RI at top pushes down")
}

// -- resize -------------------------------------------------------------------
do {
    let (s, p) = fresh(rows: 3, cols: 6)
    p.feed("abcdef\r\nghijkl\r\nmnopqr\u{1b}[3;6H")
    s.resize(rows: 2, columns: 4)
    checkEqual(s.text(row: 0), "abcd", "resize preserves top-left")
    check(s.cursorRow == 1 && s.cursorColumn == 3, "resize clamps cursor")
    s.resize(rows: 4, columns: 8)
    checkEqual(s.text(row: 0), "abcd", "grow preserves")
    checkEqual(s.text(row: 3), "", "grown rows blank")
}

// -- unknown sequences consumed silently --------------------------------------
do {
    let (s, p) = fresh()
    p.feed("\u{1b}[?2004h\u{1b}[>1;2c\u{1b}[6n\u{1b}(Bok")
    checkEqual(s.text(row: 0), "ok", "unknown CSI/charset consumed, never printed")
}

// -- character set selects consume exactly one following byte -----------------
do {
    let (s, p) = fresh()
    p.feed("\u{1b}(0abc")
    checkEqual(s.text(row: 0), "abc", "charset select eats designator only")
}

// -- Unicode ------------------------------------------------------------------
do {
    let (s, p) = fresh(rows: 2, cols: 10)
    p.feed("héllo → ✓")
    checkEqual(s.text(row: 0), "héllo → ✓", "unicode passthrough")
}

// -- SU / SD -----------------------------------------------------------------
do {
    let (s, p) = fresh(rows: 3, cols: 3)
    p.feed("aaa\r\nbbb\r\nccc\u{1b}[2S")
    checkEqual(s.text(row: 0), "ccc", "SU scrolls up")
    checkEqual(s.text(row: 1), "", "SU blanks bottom")
    p.feed("\u{1b}[1T")
    checkEqual(s.text(row: 0), "", "SD blanks top")
    checkEqual(s.text(row: 1), "ccc", "SD pushes down")
}

// ============================ Programs (pager, top) ============================
@MainActor
func runProgramTests() {

// The program contract: write() feeds the same parser the app uses; the grid is asserted.

func programIO(rows: Int, cols: Int) -> (TerminalScreen, TerminalProgramIO, () -> Bool) {
    let screen = TerminalScreen(rows: rows, columns: cols)
    let parser = AnsiParser(screen: screen)
    var exited = false
    let io = TerminalProgramIO(rows: rows, columns: cols,
                               write: { parser.feed($0) },
                               exit: { exited = true })
    return (screen, io, { exited })
}

// -- pager: paging, ends, quit ------------------------------------------------
do {
    let text = (1...30).map { String(format: "line%02d", $0) }.joined(separator: "\n")
    let (screen, io, exited) = programIO(rows: 10, cols: 20)
    let pager = PagerProgram(text: text, title: "less demo")
    pager.start(io: io)
    check(screen.isAlternate, "pager enters alt screen")
    check(!screen.cursorVisible, "pager hides cursor")
    checkEqual(screen.text(row: 0), "line01", "pager first line")
    checkEqual(screen.text(row: 8), "line09", "pager fills page")
    check(screen.text(row: 9).contains("1-9/30"), "pager status range")
    check(screen.grid[9][0].style.inverse, "pager status is inverse")
    pager.input(" ")
    checkEqual(screen.text(row: 0), "line10", "pager pages forward")
    pager.input("G")
    checkEqual(screen.text(row: 0), "line22", "pager jumps to end")
    checkEqual(screen.text(row: 8), "line30", "pager shows last line")
    pager.input("k")
    checkEqual(screen.text(row: 0), "line21", "pager scrolls back a line")
    pager.input("g")
    checkEqual(screen.text(row: 0), "line01", "pager jumps home")
    pager.input("q")
    check(exited(), "pager exits on q")
    check(!screen.isAlternate, "pager leaves alt screen")
    check(screen.cursorVisible, "pager restores cursor")
}

// -- pager: wrapping and resize -------------------------------------------------
do {
    let (screen, io, _) = programIO(rows: 5, cols: 10)
    let pager = PagerProgram(text: "abcdefghijKLMNOPQRST\nnext", title: "less wrap")
    pager.start(io: io)
    checkEqual(screen.text(row: 0), "abcdefghij", "pager wraps long line (head)")
    checkEqual(screen.text(row: 1), "KLMNOPQRST", "pager wraps long line (tail)")
    checkEqual(screen.text(row: 2), "next", "pager continues after wrap")
    pager.resize(rows: 5, columns: 20)
    screen.resize(rows: 5, columns: 20)
    pager.resize(rows: 5, columns: 20)
    checkEqual(screen.text(row: 0), "abcdefghijKLMNOPQRST", "pager rewraps on resize")
    checkEqual(screen.text(row: 1), "next", "pager rewrap collapses rows")
}

// -- pager: interrupt quits ------------------------------------------------------
do {
    let (_, io, exited) = programIO(rows: 5, cols: 10)
    let pager = PagerProgram(text: "x", title: "less int")
    pager.start(io: io)
    pager.input("\u{3}")
    check(exited(), "pager exits on ^C")
}

// -- top: live snapshot, quit ------------------------------------------------------
do {
    var tick = 0
    let (screen, io, exited) = programIO(rows: 6, cols: 30)
    let top = TopProgram(snapshot: { tick += 1; return ["alpha \(tick)", "beta"] })
    top.start(io: io)
    check(screen.isAlternate, "top enters alt screen")
    check(screen.text(row: 0).contains("top"), "top header present")
    check(screen.grid[0][0].style.inverse, "top header inverse")
    checkEqual(screen.text(row: 1), "alpha 1", "top draws snapshot")
    checkEqual(screen.text(row: 2), "beta", "top second line")
    top.resize(rows: 6, columns: 30)
    checkEqual(screen.text(row: 1), "alpha 2", "top redraws on resize")
    top.input("q")
    check(exited(), "top exits on q")
    check(!screen.isAlternate, "top leaves alt screen")
}

// -- TerminalKey: physical keys → xterm byte sequences (the stdin-encoding leg) --------------
func E(_ s: String) -> String { s.replacingOccurrences(of: "\u{1b}", with: "ESC").replacingOccurrences(of: "\u{7f}", with: "DEL") }
do {
    // Cursor keys, unmodified and with the xterm modifier parameter (n = 1 + s + 2a + 4c).
    checkEqual(E(TerminalKey.up.encoded()), "ESC[A", "up")
    checkEqual(E(TerminalKey.down.encoded()), "ESC[B", "down")
    checkEqual(E(TerminalKey.right.encoded()), "ESC[C", "right")
    checkEqual(E(TerminalKey.left.encoded()), "ESC[D", "left")
    checkEqual(E(TerminalKey.up.encoded(.ctrl)), "ESC[1;5A", "ctrl-up (mod 5)")
    checkEqual(E(TerminalKey.right.encoded([.shift])), "ESC[1;2C", "shift-right (mod 2)")
    checkEqual(E(TerminalKey.left.encoded([.shift, .ctrl])), "ESC[1;6D", "shift-ctrl-left (mod 6)")
    // Home/End as letter finals.
    checkEqual(E(TerminalKey.home.encoded()), "ESC[H", "home")
    checkEqual(E(TerminalKey.end.encoded()), "ESC[F", "end")
    // Tilde navigation keys, plain and modified.
    checkEqual(E(TerminalKey.pageUp.encoded()), "ESC[5~", "pageUp")
    checkEqual(E(TerminalKey.pageDown.encoded()), "ESC[6~", "pageDown")
    checkEqual(E(TerminalKey.delete.encoded()), "ESC[3~", "delete")
    checkEqual(E(TerminalKey.insert.encoded()), "ESC[2~", "insert")
    checkEqual(E(TerminalKey.delete.encoded(.ctrl)), "ESC[3;5~", "ctrl-delete")
    // Editing/control keys.
    checkEqual(E(TerminalKey.backspace.encoded()), "DEL", "backspace → DEL")
    checkEqual(E(TerminalKey.tab.encoded()), "\t", "tab")
    checkEqual(E(TerminalKey.backTab.encoded()), "ESC[Z", "shift-tab → backtab")
    checkEqual(E(TerminalKey.escape.encoded()), "ESC", "escape")
    checkEqual(E(TerminalKey.enter.encoded()), "\r", "enter → CR")
    // Function keys: F1–F4 are SS3, F5+ are CSI-tilde.
    checkEqual(E(TerminalKey.function(1).encoded()), "ESCOP", "F1")
    checkEqual(E(TerminalKey.function(4).encoded()), "ESCOS", "F4")
    checkEqual(E(TerminalKey.function(5).encoded()), "ESC[15~", "F5")
    checkEqual(E(TerminalKey.function(12).encoded()), "ESC[24~", "F12")
    // Ctrl+letter → control bytes: Ctrl-A=0x01, Ctrl-C=0x03, Ctrl-Z=0x1a; case-insensitive.
    check(TerminalKey.control(for: "a") == "\u{1}", "ctrl-a = 0x01")
    check(TerminalKey.control(for: "C") == "\u{3}", "ctrl-c = 0x03")
    check(TerminalKey.control(for: "z") == "\u{1a}", "ctrl-z = 0x1a")
    check(TerminalKey.control(for: "[") == "\u{1b}", "ctrl-[ = ESC")
    check(TerminalKey.control(for: " ") == "\u{0}", "ctrl-space = NUL")
    check(TerminalKey.control(for: "1") == nil, "ctrl-1 has no control byte")
    // DECCKM (application cursor keys): unmodified arrows/Home/End become SS3; modified stay
    // CSI. This is what vim/readline enable and bind against.
    checkEqual(E(TerminalKey.up.encoded(applicationCursor: true)), "ESCOA", "app-mode up → SS3")
    checkEqual(E(TerminalKey.down.encoded(applicationCursor: true)), "ESCOB", "app-mode down → SS3")
    checkEqual(E(TerminalKey.home.encoded(applicationCursor: true)), "ESCOH", "app-mode home → SS3")
    checkEqual(E(TerminalKey.end.encoded(applicationCursor: true)), "ESCOF", "app-mode end → SS3")
    checkEqual(E(TerminalKey.up.encoded(.ctrl, applicationCursor: true)), "ESC[1;5A", "app-mode ctrl-up stays CSI")
    checkEqual(E(TerminalKey.pageUp.encoded(applicationCursor: true)), "ESC[5~", "app-mode pageUp stays CSI-tilde")
    // The screen tracks DECCKM via ESC[?1h / ESC[?1l, so the terminal encodes accordingly.
    do {
        let (s, p) = fresh(rows: 3, cols: 5)
        check(!s.applicationCursorKeys, "DECCKM starts reset")
        p.feed("\u{1b}[?1h"); check(s.applicationCursorKeys, "ESC[?1h sets DECCKM")
        p.feed("\u{1b}[?1l"); check(!s.applicationCursorKeys, "ESC[?1l resets DECCKM")
    }
    // Bracketed paste (mode 2004): the screen tracks it so the terminal knows whether to wrap.
    do {
        let (s, p) = fresh(rows: 3, cols: 5)
        check(!s.bracketedPaste, "bracketed paste starts off")
        p.feed("\u{1b}[?2004h"); check(s.bracketedPaste, "ESC[?2004h enables bracketed paste")
        p.feed("\u{1b}[?2004l"); check(!s.bracketedPaste, "ESC[?2004l disables it")
    }
    // Round trip: encoded arrow keys, fed into the screen as a program's stdin echo, move the
    // cursor exactly as the escape says (proves the bytes are the ones the parser acts on).
    let (s, p) = fresh(rows: 5, cols: 10)
    p.feed("\u{1b}[3;3H")                       // park at row 3, col 3 (0-based 2,2)
    p.feed(TerminalKey.up.encoded())            // ESC[A → up one
    p.feed(TerminalKey.right.encoded())         // ESC[C → right one
    check(s.cursorRow == 1 && s.cursorColumn == 3, "encoded up+right move the cursor per xterm")
    // SS3 arrows must move the cursor identically (the parser accepts both forms).
    p.feed(TerminalKey.down.encoded(applicationCursor: true))   // ESCOB → down one
    check(s.cursorRow == 2 && s.cursorColumn == 3, "SS3 down moves the cursor like CSI")
}

}
MainActor.assumeIsolated { runProgramTests() }

if failures == 0 {
    print("ALL PASS")
} else {
    print("\(failures) FAILURES")
    exit(1)
}
