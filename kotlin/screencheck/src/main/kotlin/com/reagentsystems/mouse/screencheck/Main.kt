package com.reagentsystems.mouse.screencheck

import com.reagentsystems.mouse.terminal.AnsiColor
import com.reagentsystems.mouse.terminal.AnsiParser
import com.reagentsystems.mouse.terminal.CellStyle
import com.reagentsystems.mouse.terminal.TerminalKey
import com.reagentsystems.mouse.terminal.TerminalProgram
import com.reagentsystems.mouse.terminal.TerminalProgramIO
import com.reagentsystems.mouse.terminal.TerminalScreen
import com.reagentsystems.mouse.terminal.TerminalTty
import com.reagentsystems.mouse.terminal.TerminalWidth
import java.io.File
import kotlin.system.exitProcess

// Headless verification of the Kotlin TerminalScreen + AnsiParser + TerminalWidth + TerminalKey.
//
// The corpus is the iOS one, ported assertion for assertion, because a parity claim that is
// gated differently on the two platforms is unfalsifiable (plans/android-parity.md):
//
//   verify/main.swift       — the screen/parser/key corpus against xterm semantics
//   verify/altscreen/       — the alt screen is a save/RESTORE pair, wide text and all
//   verify/widechars/       — the width table against Python's unicodedata, plus the grid rules
//   verify/widetui/         — a TUI's boxes align, Latin and CJK alike (screen-level half)
//   verify/tty/             — the TTY join (screen-level half), incl. the pyte cross-check
//
// Two fixtures are read from `verify/` rather than copied here, so the two platforms cannot
// drift apart silently: `widths.txt` (Python's unicodedata) and `cc-frame.bin`/`cc-frame.pyte`
// (a captured claude-code frame plus pyte's rendering of it — the strongest single gate,
// because pyte is an independent emulator).
//
// No JUnit, by invariant #4: this is a main() that prints one verdict line and exits non-zero,
// the same shape as the Swift harnesses in verify/.

private var failures = 0
private var checks = 0

private fun check(condition: Boolean, label: String) {
    checks += 1
    if (!condition) {
        failures += 1
        println("  FAIL: $label")
    }
}

private fun checkEqual(got: String, want: String, label: String) {
    checks += 1
    if (got != want) {
        failures += 1
        println(
            "  FAIL: $label\n    got:  ${got.replace("\n", "\\n")}\n" +
                "    want: ${want.replace("\n", "\\n")}",
        )
    }
}

private fun fresh(rows: Int = 24, columns: Int = 80): Pair<TerminalScreen, AnsiParser> {
    val screen = TerminalScreen(rows = rows, columns = columns)
    return screen to AnsiParser(screen)
}

/** verify/altscreen and verify/widechars read a row this way: continuations dropped, both ends trimmed. */
private fun visible(screen: TerminalScreen, row: Int): String =
    screen.grid[row].filter { !it.isContinuation }.joinToString("") { it.character }.trim(' ')

/** verify/widetui reads a row this way: continuations dropped, TRAILING spaces only. */
private fun visibleKeepingIndent(screen: TerminalScreen, row: Int): String =
    screen.grid[row].filter { !it.isContinuation }.joinToString("") { it.character }.trimEnd(' ')

/** Iterate a literal the way `for ch in "中文"` does in Swift: one printable unit at a time. */
private fun putEach(screen: TerminalScreen, text: String) {
    var index = 0
    while (index < text.length) {
        val codePoint = text.codePointAt(index)
        index += Character.charCount(codePoint)
        screen.put(String(Character.toChars(codePoint)))
    }
}

private val repoRoot: File by lazy {
    val declared = System.getProperty("mouse.repo.root")
    if (declared != null) return@lazy File(declared)
    // Walk up from the working directory so the harness still finds its fixtures when it is
    // started by hand rather than through the `run` task.
    var candidate: File? = File(".").absoluteFile
    while (candidate != null) {
        if (File(candidate, "verify/tty/cc-frame.bin").exists()) return@lazy candidate
        candidate = candidate.parentFile
    }
    File(".").absoluteFile
}

// ---------------------------------------------------------------- verify/main.swift ----------

private fun screenCorpus() {
    // -- plain text, CR, LF ------------------------------------------------------
    run {
        val (s, p) = fresh(rows = 3, columns = 10)
        p.feed("hi\r\nworld")
        checkEqual(s.text(0), "hi", "plain row 0")
        checkEqual(s.text(1), "world", "plain row 1")
        check(s.cursorRow == 1 && s.cursorColumn == 5, "cursor after text")
        p.feed("\rX")
        checkEqual(s.text(1), "Xorld", "CR overprints")
    }

    // -- wrap at right edge ------------------------------------------------------
    run {
        val (s, p) = fresh(rows = 3, columns = 5)
        p.feed("abcdefg")
        checkEqual(s.text(0), "abcde", "wrap row 0")
        checkEqual(s.text(1), "fg", "wrap row 1")
    }

    // -- wrap at bottom scrolls --------------------------------------------------
    run {
        val (s, p) = fresh(rows = 2, columns = 3)
        p.feed("abcdefghi") // 3 full rows into 2 -> first scrolls off
        checkEqual(s.text(0), "def", "scroll on wrap row 0")
        checkEqual(s.text(1), "ghi", "scroll on wrap row 1")
    }

    // -- CUP / cursor moves ------------------------------------------------------
    run {
        val (s, p) = fresh()
        p.feed("\u001B[10;5H")
        check(s.cursorRow == 9 && s.cursorColumn == 4, "CUP 1-based -> 0-based")
        p.feed("\u001B[H")
        check(s.cursorRow == 0 && s.cursorColumn == 0, "CUP default home")
        p.feed("\u001B[5B\u001B[3C")
        check(s.cursorRow == 5 && s.cursorColumn == 3, "CUD+CUF")
        p.feed("\u001B[A\u001B[D")
        check(s.cursorRow == 4 && s.cursorColumn == 2, "CUU+CUB default 1")
        p.feed("\u001B[99A")
        check(s.cursorRow == 0, "CUU clamps at top")
        p.feed("\u001B[999;999H")
        check(s.cursorRow == 23 && s.cursorColumn == 79, "CUP clamps bottom-right")
        p.feed("\u001B[7G")
        check(s.cursorColumn == 6, "CHA")
        p.feed("\u001B[12d")
        check(s.cursorRow == 11 && s.cursorColumn == 6, "VPA keeps column")
    }

    // -- ED / EL -----------------------------------------------------------------
    run {
        val (s, p) = fresh(rows = 3, columns = 6)
        p.feed("aaaaaa\r\nbbbbbb\r\ncccccc")
        p.feed("\u001B[2;3H\u001B[0K") // EL to end on row 1
        checkEqual(s.text(1), "bb", "EL 0")
        p.feed("\u001B[3;3H\u001B[1K") // EL to start on row 2
        checkEqual(s.text(2), "   ccc", "EL 1 (inclusive)")
        p.feed("\u001B[2K")
        checkEqual(s.text(2), "", "EL 2")
        val (s2, p2) = fresh(rows = 3, columns = 6)
        p2.feed("aaaaaa\r\nbbbbbb\r\ncccccc\u001B[2;3H\u001B[J")
        checkEqual(s2.text(0), "aaaaaa", "ED 0 keeps above")
        checkEqual(s2.text(1), "bb", "ED 0 trims cursor row")
        checkEqual(s2.text(2), "", "ED 0 clears below")
        val (s3, p3) = fresh(rows = 3, columns = 6)
        p3.feed("aaaaaa\r\nbbbbbb\r\ncccccc\u001B[2;3H\u001B[1J")
        checkEqual(s3.text(0), "", "ED 1 clears above")
        checkEqual(s3.text(1), "   bbb", "ED 1 trims to cursor (inclusive)")
        checkEqual(s3.text(2), "cccccc", "ED 1 keeps below")
        p3.feed("\u001B[2J")
        check(s3.plainText.trim().isEmpty(), "ED 2 clears all")
    }

    // -- scroll region -----------------------------------------------------------
    run {
        val (s, p) = fresh(rows = 5, columns = 3)
        p.feed("aaa\r\nbbb\r\nccc\r\nddd\r\neee")
        p.feed("\u001B[2;4r") // region rows 1..3 (0-based)
        check(s.cursorRow == 0 && s.cursorColumn == 0, "DECSTBM homes to absolute top-left")
        p.feed("\u001B[4;3H\n") // LF at region bottom scrolls region only
        checkEqual(s.text(0), "aaa", "region scroll keeps header")
        checkEqual(s.text(1), "ccc", "region scrolled up")
        checkEqual(s.text(2), "ddd", "region scrolled up 2")
        checkEqual(s.text(3), "", "region bottom blank")
        checkEqual(s.text(4), "eee", "region scroll keeps footer")
        p.feed("\u001B[r\u001B[5;3H\n") // reset region; LF at screen bottom scrolls all
        checkEqual(s.text(0), "ccc", "full scroll after reset")
    }

    // -- IL / DL inside region ---------------------------------------------------
    run {
        val (s, p) = fresh(rows = 4, columns = 3)
        p.feed("aaa\r\nbbb\r\nccc\r\nddd")
        p.feed("\u001B[2;3r\u001B[2;1H\u001B[L") // insert line at row 1 inside region 1..2
        checkEqual(s.text(1), "", "IL blank at cursor")
        checkEqual(s.text(2), "bbb", "IL pushed down")
        checkEqual(s.text(3), "ddd", "IL respects region bottom")
        p.feed("\u001B[M")
        checkEqual(s.text(1), "bbb", "DL pulls up")
    }

    // -- ICH / DCH / ECH ---------------------------------------------------------
    run {
        val (s, p) = fresh(rows = 2, columns = 6)
        p.feed("abcdef\u001B[1;3H\u001B[2@")
        checkEqual(s.text(0), "ab  cd", "ICH shifts right, drops end")
        p.feed("\u001B[2P")
        checkEqual(s.text(0), "abcd", "DCH deletes at cursor")
        p.feed("\u001B[1;1H\u001B[2X")
        checkEqual(s.text(0), "  cd", "ECH blanks without shifting")
    }

    // -- SGR ---------------------------------------------------------------------
    run {
        val (s, p) = fresh()
        p.feed("\u001B[31mA")
        check(s.grid[0][0].style.foreground == AnsiColor.Indexed(1), "SGR 31 red")
        p.feed("\u001B[1;44mB")
        check(
            s.grid[0][1].style.bold && s.grid[0][1].style.background == AnsiColor.Indexed(4),
            "SGR 1;44",
        )
        check(s.grid[0][1].style.foreground == AnsiColor.Indexed(1), "SGR accumulates fg")
        p.feed("\u001B[0mC")
        check(s.grid[0][2].style == CellStyle.plain, "SGR 0 reset")
        p.feed("\u001B[38;5;196mD")
        check(s.grid[0][3].style.foreground == AnsiColor.Indexed(196), "SGR 256-color")
        p.feed("\u001B[48;2;10;20;30mE")
        check(s.grid[0][4].style.background == AnsiColor.Rgb(10, 20, 30), "SGR truecolor bg")
        p.feed("\u001B[0;93mF")
        check(s.grid[0][5].style.foreground == AnsiColor.Indexed(11), "SGR bright fg")
        p.feed("\u001B[7mG")
        check(s.grid[0][6].style.inverse, "SGR inverse")
        p.feed("\u001B[27;39;49mH")
        check(s.grid[0][7].style == CellStyle(bold = false), "SGR resets to default fg/bg")
        p.feed("\u001B[mI")
        check(s.grid[0][8].style == CellStyle.plain, "SGR empty = reset")
    }

    // -- erase carries background (the TUI panel rule) ---------------------------
    run {
        val (s, p) = fresh(rows = 2, columns = 4)
        p.feed("\u001B[44m\u001B[2J")
        check(s.grid[1][3].style.background == AnsiColor.Indexed(4), "ED paints background")
        check(s.grid[1][3].character == " ", "ED blanks characters")
    }

    // -- alt screen --------------------------------------------------------------
    run {
        val (s, p) = fresh(rows = 2, columns = 5)
        p.feed("shell")
        p.feed("\u001B[?1049h")
        check(s.isAlternate, "alt screen entered")
        checkEqual(s.plainText, "\n", "alt screen starts clear")
        check(s.cursorRow == 0 && s.cursorColumn == 0, "alt screen homes")
        p.feed("vim!!")
        p.feed("\u001B[?1049l")
        check(!s.isAlternate, "alt screen left")
        // 47 / 1047 too
        p.feed("\u001B[?47h")
        check(s.isAlternate, "mode 47 enters alt")
        p.feed("\u001B[?1047l")
        check(!s.isAlternate, "mode 1047 leaves alt")
    }

    // -- cursor visibility, save/restore -----------------------------------------
    run {
        val (s, p) = fresh()
        p.feed("\u001B[?25l")
        check(!s.cursorVisible, "DECTCEM hide")
        p.feed("\u001B[?25h")
        check(s.cursorVisible, "DECTCEM show")
        p.feed("\u001B[5;5H\u001B[31m\u001B7\u001B[H\u001B[0m\u001B8")
        check(s.cursorRow == 4 && s.cursorColumn == 4, "DECRC position")
        check(s.style.foreground == AnsiColor.Indexed(1), "DECRC restores style")
        p.feed("\u001B[10;10H\u001B[s\u001B[H\u001B[u")
        check(s.cursorRow == 9 && s.cursorColumn == 9, "CSI s/u")
    }

    // -- split sequences across feeds --------------------------------------------
    run {
        val (s, p) = fresh()
        p.feed("\u001B")
        p.feed("[")
        p.feed("3")
        p.feed("1")
        p.feed("m")
        p.feed("\u001B[2;")
        p.feed("2H")
        p.feed("X")
        check(
            s.grid[1][1].character == "X" && s.grid[1][1].style.foreground == AnsiColor.Indexed(1),
            "split sequence survives feed boundaries",
        )
    }

    // -- OSC swallowed (BEL and ST terminators) ----------------------------------
    run {
        val (s, p) = fresh()
        p.feed("\u001B]0;my title\u0007after")
        checkEqual(s.text(0), "after", "OSC BEL swallowed")
        val (s2, p2) = fresh()
        p2.feed("\u001B]2;title\u001B\\after")
        checkEqual(s2.text(0), "after", "OSC ST swallowed")
    }

    // -- tabs, backspace, bell ---------------------------------------------------
    run {
        val (s, p) = fresh(rows = 2, columns = 20)
        p.feed("ab\tX")
        check(s.grid[0][8].character == "X", "tab to next 8-stop")
        p.feed("\u0008\u0008Y")
        check(s.grid[0][7].character == "Y", "backspace moves left")
        p.feed("\u0007") // bell: no crash, no output
        val (s2, p2) = fresh(rows = 2, columns = 4)
        p2.feed("\u0008Z")
        check(s2.grid[0][0].character == "Z", "backspace clamps at col 0")
    }

    // -- RIS ----------------------------------------------------------------------
    run {
        val (s, p) = fresh(rows = 2, columns = 4)
        p.feed("\u001B[31mab\u001Bc")
        check(s.plainText.trim().isEmpty(), "RIS clears")
        check(s.style == CellStyle.plain, "RIS resets style")
        check(s.cursorRow == 0 && s.cursorColumn == 0, "RIS homes")
    }

    // -- reverse index at top of region scrolls down ------------------------------
    run {
        val (s, p) = fresh(rows = 3, columns = 3)
        p.feed("aaa\r\nbbb\r\nccc\u001B[1;1H\u001BM")
        // xterm: RI at absolute top inserts a blank line, pushing content down
        checkEqual(s.text(0), "", "RI at top scrolls down (blank)")
        checkEqual(s.text(1), "aaa", "RI at top pushes down")
    }

    // -- resize -------------------------------------------------------------------
    run {
        val (s, p) = fresh(rows = 3, columns = 6)
        p.feed("abcdef\r\nghijkl\r\nmnopqr\u001B[3;6H")
        s.resize(rows = 2, columns = 4)
        checkEqual(s.text(0), "abcd", "resize preserves top-left")
        check(s.cursorRow == 1 && s.cursorColumn == 3, "resize clamps cursor")
        s.resize(rows = 4, columns = 8)
        checkEqual(s.text(0), "abcd", "grow preserves")
        checkEqual(s.text(3), "", "grown rows blank")
    }

    // -- unknown sequences consumed silently --------------------------------------
    run {
        val (s, p) = fresh()
        p.feed("\u001B[?2004h\u001B[>1;2c\u001B[6n\u001B(Bok")
        checkEqual(s.text(0), "ok", "unknown CSI/charset consumed, never printed")
    }

    // -- character set selects consume exactly one following byte -----------------
    run {
        val (s, p) = fresh()
        p.feed("\u001B(0abc")
        checkEqual(s.text(0), "abc", "charset select eats designator only")
    }

    // -- Unicode ------------------------------------------------------------------
    run {
        val (s, p) = fresh(rows = 2, columns = 10)
        // Written with explicit scalars: Swift's String comparison is canonical-equivalence
        // based, so "héllo" there matches either normalisation. Kotlin compares code units, so
        // the expectation says which one it means.
        p.feed("h\u00E9llo \u2192 \u2713")
        checkEqual(s.text(0), "h\u00E9llo \u2192 \u2713", "unicode passthrough")
    }

    // -- SU / SD -----------------------------------------------------------------
    run {
        val (s, p) = fresh(rows = 3, columns = 3)
        p.feed("aaa\r\nbbb\r\nccc\u001B[2S")
        checkEqual(s.text(0), "ccc", "SU scrolls up")
        checkEqual(s.text(1), "", "SU blanks bottom")
        p.feed("\u001B[1T")
        checkEqual(s.text(0), "", "SD blanks top")
        checkEqual(s.text(1), "ccc", "SD pushes down")
    }
}

// ------------------------------------------------------- verify/main.swift: TerminalKey ------

private fun readable(text: String): String =
    text.replace("\u001B", "ESC").replace("\u007F", "DEL")

private fun keyCorpus() {
    val ctrl = TerminalKey.Modifiers.ctrl
    val shift = TerminalKey.Modifiers.shift
    // Cursor keys, unmodified and with the xterm modifier parameter (n = 1 + s + 2a + 4c).
    checkEqual(readable(TerminalKey.Up.encoded()), "ESC[A", "up")
    checkEqual(readable(TerminalKey.Down.encoded()), "ESC[B", "down")
    checkEqual(readable(TerminalKey.Right.encoded()), "ESC[C", "right")
    checkEqual(readable(TerminalKey.Left.encoded()), "ESC[D", "left")
    checkEqual(readable(TerminalKey.Up.encoded(ctrl)), "ESC[1;5A", "ctrl-up (mod 5)")
    checkEqual(readable(TerminalKey.Right.encoded(shift)), "ESC[1;2C", "shift-right (mod 2)")
    checkEqual(readable(TerminalKey.Left.encoded(shift + ctrl)), "ESC[1;6D", "shift-ctrl-left (mod 6)")
    // Home/End as letter finals.
    checkEqual(readable(TerminalKey.Home.encoded()), "ESC[H", "home")
    checkEqual(readable(TerminalKey.End.encoded()), "ESC[F", "end")
    // Tilde navigation keys, plain and modified.
    checkEqual(readable(TerminalKey.PageUp.encoded()), "ESC[5~", "pageUp")
    checkEqual(readable(TerminalKey.PageDown.encoded()), "ESC[6~", "pageDown")
    checkEqual(readable(TerminalKey.Delete.encoded()), "ESC[3~", "delete")
    checkEqual(readable(TerminalKey.Insert.encoded()), "ESC[2~", "insert")
    checkEqual(readable(TerminalKey.Delete.encoded(ctrl)), "ESC[3;5~", "ctrl-delete")
    // Editing/control keys.
    checkEqual(readable(TerminalKey.Backspace.encoded()), "DEL", "backspace -> DEL")
    checkEqual(readable(TerminalKey.Tab.encoded()), "\t", "tab")
    checkEqual(readable(TerminalKey.BackTab.encoded()), "ESC[Z", "shift-tab -> backtab")
    checkEqual(readable(TerminalKey.Escape.encoded()), "ESC", "escape")
    checkEqual(readable(TerminalKey.Enter.encoded()), "\r", "enter -> CR")
    // Function keys: F1-F4 are SS3, F5+ are CSI-tilde.
    checkEqual(readable(TerminalKey.Function(1).encoded()), "ESCOP", "F1")
    checkEqual(readable(TerminalKey.Function(4).encoded()), "ESCOS", "F4")
    checkEqual(readable(TerminalKey.Function(5).encoded()), "ESC[15~", "F5")
    checkEqual(readable(TerminalKey.Function(12).encoded()), "ESC[24~", "F12")
    // Ctrl+letter -> control bytes: Ctrl-A=0x01, Ctrl-C=0x03, Ctrl-Z=0x1a; case-insensitive.
    check(TerminalKey.control('a') == "\u0001", "ctrl-a = 0x01")
    check(TerminalKey.control('C') == "\u0003", "ctrl-c = 0x03")
    check(TerminalKey.control('z') == "\u001A", "ctrl-z = 0x1a")
    check(TerminalKey.control('[') == "\u001B", "ctrl-[ = ESC")
    check(TerminalKey.control(' ') == "\u0000", "ctrl-space = NUL")
    check(TerminalKey.control('1') == null, "ctrl-1 has no control byte")
    // DECCKM (application cursor keys): unmodified arrows/Home/End become SS3; modified stay
    // CSI. This is what vim/readline enable and bind against.
    checkEqual(readable(TerminalKey.Up.encoded(applicationCursor = true)), "ESCOA", "app-mode up -> SS3")
    checkEqual(readable(TerminalKey.Down.encoded(applicationCursor = true)), "ESCOB", "app-mode down -> SS3")
    checkEqual(readable(TerminalKey.Home.encoded(applicationCursor = true)), "ESCOH", "app-mode home -> SS3")
    checkEqual(readable(TerminalKey.End.encoded(applicationCursor = true)), "ESCOF", "app-mode end -> SS3")
    checkEqual(
        readable(TerminalKey.Up.encoded(ctrl, applicationCursor = true)), "ESC[1;5A",
        "app-mode ctrl-up stays CSI",
    )
    checkEqual(
        readable(TerminalKey.PageUp.encoded(applicationCursor = true)), "ESC[5~",
        "app-mode pageUp stays CSI-tilde",
    )
    // The screen tracks DECCKM via ESC[?1h / ESC[?1l, so the terminal encodes accordingly.
    run {
        val (s, p) = fresh(rows = 3, columns = 5)
        check(!s.applicationCursorKeys, "DECCKM starts reset")
        p.feed("\u001B[?1h"); check(s.applicationCursorKeys, "ESC[?1h sets DECCKM")
        p.feed("\u001B[?1l"); check(!s.applicationCursorKeys, "ESC[?1l resets DECCKM")
    }
    // Bracketed paste (mode 2004): the screen tracks it so the terminal knows whether to wrap.
    run {
        val (s, p) = fresh(rows = 3, columns = 5)
        check(!s.bracketedPaste, "bracketed paste starts off")
        p.feed("\u001B[?2004h"); check(s.bracketedPaste, "ESC[?2004h enables bracketed paste")
        p.feed("\u001B[?2004l"); check(!s.bracketedPaste, "ESC[?2004l disables it")
    }
    // Round trip: encoded arrow keys, fed into the screen as a program's stdin echo, move the
    // cursor exactly as the escape says (proves the bytes are the ones the parser acts on).
    run {
        val (s, p) = fresh(rows = 5, columns = 10)
        p.feed("\u001B[3;3H") // park at row 3, col 3 (0-based 2,2)
        p.feed(TerminalKey.Up.encoded()) // ESC[A -> up one
        p.feed(TerminalKey.Right.encoded()) // ESC[C -> right one
        check(s.cursorRow == 1 && s.cursorColumn == 3, "encoded up+right move the cursor per xterm")
        // SS3 arrows must move the cursor identically (the parser accepts both forms).
        p.feed(TerminalKey.Down.encoded(applicationCursor = true)) // ESCOB -> down one
        check(s.cursorRow == 2 && s.cursorColumn == 3, "SS3 down moves the cursor like CSI")
    }
}

// ------------------------------------------------- the TerminalProgram contract ---------------

/**
 * iOS gates the program contract with PagerProgram and TopProgram. Those are the pager and the
 * process monitor, not the screen, and they are deliberately NOT ported yet — so the contract
 * itself is gated with the smallest program that can exercise every part of it: stdout draws,
 * stdin is keys, resize is SIGWINCH, exit restores.
 */
private class ContractProgram : TerminalProgram {
    override val title = "contract"
    override var rendersScreen = false
    private var io: TerminalProgramIO? = null

    override fun start(io: TerminalProgramIO) {
        this.io = io
        rendersScreen = true
        io.write("\u001B[?1049h\u001B[?25l\u001B[Hhello")
        io.modeChanged()
    }

    override fun input(text: String) {
        val io = io ?: return
        if (text == "q" || text == "\u0003") {
            io.write("\u001B[?25h\u001B[?1049l")
            io.exit()
        } else {
            io.write(text.uppercase())
        }
    }

    override fun resize(rows: Int, columns: Int) {
        io?.write("\u001B[2;1H\u001B[2K${rows}x$columns")
    }
}

private fun programContract() {
    val screen = TerminalScreen(rows = 6, columns = 20)
    val parser = AnsiParser(screen)
    var exited = false
    var modeFlips = 0
    val program = ContractProgram()
    program.start(
        TerminalProgramIO(
            rows = 6,
            columns = 20,
            write = { parser.feed(it) },
            exit = { exited = true },
            modeChanged = { modeFlips += 1 },
        ),
    )
    check(screen.isAlternate, "program enters the alt screen")
    check(!screen.cursorVisible, "program hides the cursor")
    check(program.rendersScreen, "program took the screen")
    check(modeFlips == 1, "the host is TOLD about the mode flip, not left to observe it")
    checkEqual(screen.text(0), "hello", "program painted through io.write")
    program.input("h")
    program.input("i")
    checkEqual(screen.text(0), "helloHI", "keystrokes reach the program and redraw")
    program.resize(rows = 6, columns = 20)
    checkEqual(screen.text(1), "6x20", "resize is SIGWINCH: the program repaints its geometry")
    program.input("q")
    check(exited, "program exits on q")
    check(!screen.isAlternate, "exit restores the normal screen")
    check(screen.cursorVisible, "exit restores the cursor")
}

// ------------------------------------------------------------- verify/altscreen ---------------

private fun altScreenCorpus() {
    // The ordinary cycle a TUI performs.
    val screen = TerminalScreen(rows = 8, columns = 24)
    val parser = AnsiParser(screen)
    parser.feed("\u001B[Hmain \u4E2D\u6587 work")
    parser.feed("\u001B[2;1Hsecond line")
    parser.feed("\u001B[2;5H") // a cursor position worth restoring
    val beforeRow = visible(screen, 0)
    val beforeColumn = screen.cursorColumn
    parser.feed("\u001B[?1049h")
    checkEqual(visible(screen, 0), "", "alt starts cleared")
    parser.feed("\u001B[Halt \u65E5\u672C\u8A9E screen")
    checkEqual(visible(screen, 0), "alt \u65E5\u672C\u8A9E screen", "alt draws")
    parser.feed("\u001B[?1049l")
    checkEqual(visible(screen, 0), beforeRow, "normal screen restored")
    checkEqual(visible(screen, 1), "second line", "second line restored")
    checkEqual("${screen.cursorColumn}", "$beforeColumn", "cursor restored")

    // Wide text must survive the save/restore with its columns intact, not collapse to one cell.
    checkEqual(screen.grid[0][5].character, "\u4E2D", "wide survives round trip")
    checkEqual(
        if (screen.grid[0][6].isContinuation) "cont" else "plain", "cont",
        "continuation survives",
    )

    // Leaving an alternate screen never entered must not destroy anything.
    val s2 = TerminalScreen(rows = 4, columns = 20)
    val p2 = AnsiParser(s2)
    p2.feed("\u001B[Huntouched")
    p2.feed("\u001B[?1049l")
    checkEqual(visible(s2, 0), "untouched", "bare leave is a no-op")

    // Entering twice must not lose the ORIGINAL normal screen behind the second save.
    val s3 = TerminalScreen(rows = 4, columns = 20)
    val p3 = AnsiParser(s3)
    p3.feed("\u001B[Horiginal")
    p3.feed("\u001B[?1049h\u001B[Hfirst alt")
    p3.feed("\u001B[?1049h\u001B[Hsecond alt") // already alternate: a no-op, not a re-save
    p3.feed("\u001B[?1049l")
    checkEqual(visible(s3, 0), "original", "double enter keeps original")
}

// ------------------------------------------------------------- verify/widechars ---------------

private fun widthCorpus() {
    val fixture = File(repoRoot, "verify/widechars/widths.txt")
    if (!fixture.exists()) {
        check(false, "widths.txt fixture not found at ${fixture.path}")
    } else {
        var checked = 0
        var wrong = 0
        for (line in fixture.readLines()) {
            val parts = line.trim().split(" ")
            if (parts.size != 2 || !parts[0].startsWith("U+")) continue
            val value = parts[0].substring(2).toIntOrNull(16) ?: continue
            val want = parts[1].toIntOrNull() ?: continue
            // Surrogate halves are not scalars; Swift's `Unicode.Scalar(value)` returns nil.
            if (value in 0xD800..0xDFFF) continue
            val got = TerminalWidth.columns(String(Character.toChars(value)))
            checked += 1
            if (got != want) {
                if (wrong < 6) {
                    println("  U+${value.toString(16).uppercase()}: unicodedata=$want ours=$got")
                }
                wrong += 1
            }
        }
        checks += 1
        if (wrong > 0) {
            failures += 1
            println("  FAIL: width table: $wrong of $checked disagree with Unicode")
        } else {
            println("  width table: all $checked agree with Python's unicodedata")
        }
    }

    // The grid itself.
    var screen = TerminalScreen(rows = 4, columns = 10)
    putEach(screen, "\u4E2D\u6587")
    checkEqual("${screen.cursorColumn}", "4", "cursor after two wide")
    checkEqual(visible(screen, 0), "\u4E2D\u6587", "wide text")

    screen = TerminalScreen(rows = 4, columns = 10)
    putEach(screen, "ab")
    checkEqual("${screen.cursorColumn}", "2", "cursor after two narrow")

    // A wide character with one column left must wrap WHOLE, not split.
    screen = TerminalScreen(rows = 4, columns = 4)
    putEach(screen, "abc")
    screen.put("\u4E2D")
    checkEqual(visible(screen, 0), "abc", "wrapped whole")
    checkEqual(visible(screen, 1), "\u4E2D", "wide moved to next row")

    // Overwriting half a wide pair must clear its partner, or the grid keeps an orphan.
    screen = TerminalScreen(rows = 4, columns = 10)
    screen.put("\u4E2D"); screen.moveCursor(0, 0); screen.put("x")
    checkEqual(visible(screen, 0), "x", "partner cleared")
    screen = TerminalScreen(rows = 4, columns = 10)
    screen.put("\u4E2D"); screen.moveCursor(0, 1); screen.put("y")
    checkEqual(visible(screen, 0), "y", "left half cleared")

    // A combining mark attaches to the character already there rather than taking a column.
    screen = TerminalScreen(rows = 4, columns = 10)
    screen.put("e"); screen.put("\u0301")
    checkEqual("${screen.cursorColumn}", "1", "combining attaches")
    // Swift writes this expectation as "é": its String comparison is canonical-equivalence
    // based, so the decomposed cell matches. Kotlin compares code units, so the expectation
    // spells out what the cell actually holds — the same grid, a stricter comparison.
    checkEqual(visible(screen, 0), "e\u0301", "combined glyph")

    // Mixed content keeps its column arithmetic.
    screen = TerminalScreen(rows = 4, columns = 12)
    putEach(screen, "a\u4E2Db")
    checkEqual("${screen.cursorColumn}", "4", "mixed cursor")
    checkEqual(visible(screen, 0), "a\u4E2Db", "mixed text")
}

// --------------------------------------------------------------- verify/widetui ---------------

private fun wideTuiCorpus() {
    // The screen-level half of verify/widetui: the exact byte stream that harness's Node program
    // writes, through the same ONLCR the TTY applies. (The Node half is milestone 3.)
    val screen = TerminalScreen(rows = 10, columns = 40)
    val parser = AnsiParser(screen)
    fun write(text: String) = parser.feed(TerminalTty.onlcr(text))
    write("\u001B[?1049h\u001B[H")
    write("|abcd|\r\n")
    write("|\u4E2D\u6587|\r\n")
    write("|a\u4E2Db|\r\n")
    write("\u001B[5;1H\u65E5\u672C\u8A9E")
    write("\u001B[5;7Hok")

    checkEqual(visibleKeepingIndent(screen, 0), "|abcd|", "latin row")
    checkEqual(visibleKeepingIndent(screen, 1), "|\u4E2D\u6587|", "cjk row")
    checkEqual(visibleKeepingIndent(screen, 2), "|a\u4E2Db|", "mixed row")
    // The whole point: the closing bar lands in the SAME column on every row. One column per
    // character puts it at 3 on the CJK row and the box comes out ragged.
    checkEqual(screen.grid[0][5].character, "|", "latin close column")
    checkEqual(screen.grid[1][5].character, "|", "cjk close column")
    checkEqual(screen.grid[2][5].character, "|", "mixed close column")
    // Absolute positioning agrees with the same arithmetic: 日本語 is six columns.
    checkEqual(visibleKeepingIndent(screen, 4), "\u65E5\u672C\u8A9Eok", "wide then positioned")
    checkEqual(screen.grid[4][6].character, "o", "positioned lands at 6")
}

// ------------------------------------------------------------------- verify/tty ---------------

private fun ttyCorpus() {
    // -- 3: a raw-mode program's paint and its keystroke redraws land on the grid ------------
    run {
        val (s, p) = fresh(rows = 6, columns = 20)
        p.feed("\u001B[2J\u001B[H> ")
        checkEqual(s.text(0), ">", "prompt painted on grid (trailing blank trimmed)")
        p.feed("H"); p.feed("I")
        checkEqual(s.text(0), "> HI", "keystrokes drawn after redraw")
        p.feed("\u001B[2;1Hbye")
        checkEqual(s.text(1), "bye", "program drew its goodbye")
    }

    // -- 7: alt screen flips to the grid, exit restores the main screen ----------------------
    run {
        val (s, p) = fresh(rows = 6, columns = 20)
        p.feed("\u001B[?1049h\u001B[Hfull-screen")
        check(s.isAlternate, "alt screen taken")
        checkEqual(s.text(0), "full-screen", "paint landed on the grid")
        p.feed("\u001B[?25h\u001B[?1049l") // what a program writes on the way out
        check(!s.isAlternate, "main screen restored on exit")
    }

    // -- 16: terminal query -> response round trip (DSR/DA/DECRQM) ---------------------------
    run {
        val (s, p) = fresh(rows = 10, columns = 40)
        val replies = StringBuilder()
        p.respond = { replies.append(it) }
        p.feed("\u001B[1;6H") // park cursor at row 1, col 6
        p.feed("\u001B[6n") // DSR: where is the cursor?
        p.feed("\u001B[c") // DA: what are you?
        p.feed("\u001B[?2026\u0024p") // DECRQM: is synchronized output set?
        val seen = replies.toString().replace("\u001B", "ESC")
        check(seen.contains("ESC[1;6R"), "DSR answers the cursor position")
        check(seen.contains("ESC[?6c"), "DA answers a VT102")
        check(seen.contains("ESC[?2026;2\u0024y"), "DECRQM answers recognized-but-reset")
        check(s.cursorRow == 0 && s.cursorColumn == 5, "the queries left the cursor where it was")
    }

    // -- 17: the screen tracks bracketed paste, so the host knows whether to wrap -------------
    run {
        val (s, p) = fresh(rows = 8, columns = 40)
        p.feed("\u001B[?2004h")
        check(s.bracketedPaste, "program enabled bracketed paste")
    }

    // -- 15: a REAL claude-code ink frame renders aligned via ONLCR, vs pyte ------------------
    // Captured bytes from claude-code 1.0.128's config-recovery UI: a bordered box whose lines
    // end in bare `\n`. Without ONLCR the frame shears diagonally (LF is index). The reference
    // is pyte's rendering of the same bytes — an independent emulator, which is what makes this
    // the strongest single assertion in the suite.
    run {
        val frameFile = File(repoRoot, "verify/tty/cc-frame.bin")
        val referenceFile = File(repoRoot, "verify/tty/cc-frame.pyte")
        if (!frameFile.exists() || !referenceFile.exists()) {
            check(false, "could not load cc-frame fixtures from ${frameFile.parent}")
        } else {
            val frame = String(frameFile.readBytes(), Charsets.UTF_8)
            val reference = referenceFile.readText(Charsets.UTF_8)
            val screen = TerminalScreen(rows = 30, columns = 80)
            AnsiParser(screen).feed(TerminalTty.onlcr(frame)) // the behaviour under test
            val referenceLines = reference.split("\n")
            var mismatches = 0
            for (row in 0 until 30) {
                val got = screen.text(row)
                val want = if (row < referenceLines.size) referenceLines[row] else ""
                if (got.trim(' ') != want.trim(' ')) {
                    if (mismatches < 4) {
                        println("  row $row: pyte ${want.trim(' ')}")
                        println("           ours ${got.trim(' ')}")
                    }
                    mismatches += 1
                }
            }
            check(mismatches == 0, "real ink frame renders row-for-row vs pyte (ONLCR applied)")
            check(screen.text(0).startsWith("\u256D\u2500"), "box top border at column 0")
            check(
                screen.text(2).contains("\u2502 Configuration Error"),
                "content aligned inside the box",
            )
            // And prove the shear is real: WITHOUT onlcr the same frame must NOT align.
            val bad = TerminalScreen(rows = 30, columns = 80)
            AnsiParser(bad).feed(frame)
            check(
                !bad.text(2).contains("\u2502 Configuration Error"),
                "without ONLCR the frame shears (control)",
            )
        }
    }
}

fun main() {
    println("screencheck — the iOS phase-T corpus, ported (fixtures from ${repoRoot.path}/verify)")
    screenCorpus()
    keyCorpus()
    programContract()
    altScreenCorpus()
    widthCorpus()
    wideTuiCorpus()
    ttyCorpus()

    if (failures == 0) {
        println("SCREEN CORPUS: $checks checks — grid, parser, widths, keys, program contract, pyte frame — MATCH")
    } else {
        println("SCREEN CORPUS: $failures of $checks checks disagree with the iOS gate — MISMATCH")
        exitProcess(1)
    }
}
