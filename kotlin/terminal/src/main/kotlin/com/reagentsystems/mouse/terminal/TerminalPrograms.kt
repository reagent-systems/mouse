package com.reagentsystems.mouse.terminal

/**
 * A physical key, encoded to the bytes a terminal program reads on stdin. The keyboard
 * layer (the key strip, or the field's backspace) maps a hardware key to one of these; the
 * encoding is xterm's, so a TUI navigates with the arrows, edits with backspace, and reads
 * Ctrl-combos exactly as it would on a real terminal. Platform-free, so it verifies in the
 * screen harness alongside the parser.
 *
 * Kotlin note: Swift's `enum` with an associated value becomes a sealed class, and its
 * `OptionSet` becomes a value-typed bit set. `Modifiers.rawValue` keeps the same numbering,
 * because the wire format is `1 + rawValue`.
 */
sealed class TerminalKey {
    data object Up : TerminalKey()
    data object Down : TerminalKey()
    data object Right : TerminalKey()
    data object Left : TerminalKey()
    data object Home : TerminalKey()
    data object End : TerminalKey()
    data object PageUp : TerminalKey()
    data object PageDown : TerminalKey()
    data object Insert : TerminalKey()
    data object Delete : TerminalKey()
    data object Backspace : TerminalKey()
    data object Tab : TerminalKey()
    data object BackTab : TerminalKey()
    data object Escape : TerminalKey()
    data object Enter : TerminalKey()

    /** F1…F12. */
    data class Function(val number: Int) : TerminalKey()

    data class Modifiers(val rawValue: Int) {
        val isEmpty: Boolean get() = rawValue == 0

        operator fun plus(other: Modifiers) = Modifiers(rawValue or other.rawValue)

        companion object {
            val none = Modifiers(0)
            val shift = Modifiers(1)
            val alt = Modifiers(2)
            val ctrl = Modifiers(4)
        }
    }

    /**
     * The byte sequence for this key. `modifiers` shapes cursor/navigation keys the xterm
     * way (`ESC[1;<n><final>`, n = 1 + shift + 2·alt + 4·ctrl). `applicationCursor` is DECCKM
     * (`ESC[?1h`): while set, the unmodified arrows/Home/End encode as SS3 (`ESC O <final>`)
     * rather than CSI — modified keys always stay CSI, matching xterm.
     */
    fun encoded(
        modifiers: Modifiers = Modifiers.none,
        applicationCursor: Boolean = false,
    ): String {
        val esc = ESCAPE_BYTE
        // A letter-final cursor key: `ESC[<final>` (or SS3 `ESC O <final>` in application
        // mode), or `ESC[1;<n><final>` with modifiers.
        fun letterKey(final: String): String {
            if (modifiers.isEmpty) return if (applicationCursor) "${esc}O$final" else "$esc[$final"
            return "$esc[1;${1 + modifiers.rawValue}$final"
        }
        // A tilde-final navigation key: `ESC[<num>~`, or `ESC[<num>;<n>~` with modifiers.
        fun tildeKey(number: Int): String =
            if (modifiers.isEmpty) "$esc[$number~" else "$esc[$number;${1 + modifiers.rawValue}~"

        return when (this) {
            Up -> letterKey("A")
            Down -> letterKey("B")
            Right -> letterKey("C")
            Left -> letterKey("D")
            Home -> letterKey("H")
            End -> letterKey("F")
            Insert -> tildeKey(2)
            Delete -> tildeKey(3)
            PageUp -> tildeKey(5)
            PageDown -> tildeKey(6)
            Backspace -> "\u007F" // DEL, what terminals send for Backspace
            Tab -> "\t"
            BackTab -> "$esc[Z"
            Escape -> esc
            Enter -> "\r"
            is Function -> when (number) {
                1 -> "${esc}OP"
                2 -> "${esc}OQ"
                3 -> "${esc}OR"
                4 -> "${esc}OS"
                5 -> "$esc[15~"
                6 -> "$esc[17~"
                7 -> "$esc[18~"
                8 -> "$esc[19~"
                9 -> "$esc[20~"
                10 -> "$esc[21~"
                11 -> "$esc[23~"
                12 -> "$esc[24~"
                else -> ""
            }
        }
    }

    companion object {
        private const val ESCAPE_BYTE = "\u001B"

        /**
         * Ctrl+letter → its control byte (Ctrl-A = 0x01 … Ctrl-Z = 0x1a). Also the handful of
         * symbol controls terminals define (`Ctrl-[` = ESC, `Ctrl-\`, `Ctrl-]`, `Ctrl-_`).
         */
        fun control(character: Char): String? {
            val ascii = character.code
            if (ascii > 0x7F) return null
            return when (ascii) {
                in 0x40..0x5F -> (ascii and 0x1F).toChar().toString() // @A–Z[\]^_
                in 0x61..0x7A -> ((ascii - 0x20) and 0x1F).toChar().toString() // a–z
                0x20 -> "\u0000" // Ctrl-Space → NUL
                else -> null
            }
        }
    }
}

/**
 * A full-screen terminal PROGRAM — the second thing the terminal can host.
 *
 * The prompt-and-scrollback model runs a command to completion and appends what it said. A
 * program instead OWNS the screen and the keyboard for as long as it runs: it draws by
 * writing ANSI through `TerminalProgramIO.write`, receives every keystroke through `input`,
 * and ends by calling `io.exit`. This is Mouse's stand-in for a foreground process on a PTY —
 * a "process" is an object honoring the same contract a spawned binary would: stdout draws,
 * stdin is keys, resize is SIGWINCH. Everything later on the roadmap that runs interactively
 * (agent CLIs, editors, wasm processes) enters the terminal through this interface.
 *
 * Platform-free by design: programs verify headlessly by wiring `write` into an `AnsiParser`
 * and asserting the grid. iOS marks this `@MainActor`; Kotlin has no such annotation, and the
 * discipline is the same — implementations are main-thread state, and anything that produces
 * output off-thread must hop before calling `write`.
 */
interface TerminalProgram {
    /** Shown where the prompt lives while the program runs ("less README.md", "top"). */
    val title: String

    /**
     * True when this program draws on the SCREEN (alt screen / raw keys); false while it
     * merely streams lines, which belong in the scrollback. `less` and `top` are always
     * true; a Node program decides at runtime — `node build.js` prints, `node tui.js` draws.
     */
    val rendersScreen: Boolean

    /**
     * Called once. Enter the alt screen first (`ESC[?1049h`) — the terminal renders the grid
     * while a program is running — then paint.
     */
    fun start(io: TerminalProgramIO)

    /**
     * One keystroke: a printable character, "\r", or an arrow key's escape sequence
     * (`ESC[A`…). ^C arrives as "\u0003"; programs decide what quitting means.
     */
    fun input(text: String)

    /** The visible grid changed size (rotation): adopt it and repaint. */
    fun resize(rows: Int, columns: Int)
}

/**
 * The kernel side of a running program: its stdout, its exit(2), and the screen geometry it
 * was born with.
 */
data class TerminalProgramIO(
    val rows: Int,
    val columns: Int,
    val write: (String) -> Unit,
    val exit: () -> Unit,
    /**
     * The program's `rendersScreen` flipped mid-run (a Node program deciding it is a TUI).
     * The host must hear about it through a call, not by re-reading the property: the flip
     * is invisible to observation — `rendersScreen` lives on a plain program object — and a
     * terminal that keyed its display on the property alone kept showing the scrollback while
     * a TUI drew on the grid nobody rendered. That was the phone bug.
     */
    val modeChanged: () -> Unit = {},
)

/**
 * The line discipline a PTY would apply, which here has no kernel to live in.
 *
 * On iOS this function is a static on `NodeProgram`; the comment there says why it exists at
 * all — "ONLCR, the TTY's job, not the emulator's… We are the PTY substitute, so the
 * translation belongs here". On Android it is lifted out to the terminal module because it is
 * tty truth, not runtime truth: the screen's own gate needs it (a real captured ink frame
 * only renders square with ONLCR applied), and the Node layer that will call it is milestone 3.
 */
object TerminalTty {
    /**
     * ONLCR: a bare `\n` (not already preceded by `\r`) becomes `\r\n`. A stray `\r\n`
     * split across two writes yields a harmless `\r\r\n` (CR to column 0 is idempotent),
     * so no cross-chunk state is needed.
     *
     * A program that ends lines with a bare `\n` (ink's inline frames, every logUpdate-style
     * repaint) lands each line at column 0 because of this. Without it the screen — correctly
     * xterm-faithful, LF is index — shears the frame diagonally.
     */
    fun onlcr(text: String): String {
        if (!text.contains('\n')) return text
        val result = StringBuilder(text.length + 8)
        var previous = '\u0000'
        for (character in text) {
            if (character == '\n' && previous != '\r') result.append('\r')
            result.append(character)
            previous = character
        }
        return result.toString()
    }
}

/**
 * `less`/`more` — the pager, and the proof program for the screen model. Wraps long lines,
 * scrolls by line or page, and pins an inverse status bar to the bottom row, exactly the way
 * a real pager exercises a real terminal.
 *
 * A direct port of `PagerProgram` in swift/Mouse/TerminalPrograms.swift, down to the key
 * bindings and the status-bar text, so `verify/`'s pager fixtures gate both platforms.
 */
class PagerProgram(text: String, override val title: String) : TerminalProgram {
    override val rendersScreen = true

    private val lines: List<String> = (if (text.endsWith("\n")) text.dropLast(1) else text).split("\n")
    private var wrapped: List<String> = emptyList()

    /** First visible wrapped row. */
    private var top = 0
    private var rows = 24
    private var columns = 80
    private var io: TerminalProgramIO? = null

    override fun start(io: TerminalProgramIO) {
        this.io = io
        rows = io.rows
        columns = io.columns
        rewrap()
        io.write("\u001B[?1049h\u001B[?25l")
        draw()
    }

    override fun input(text: String) {
        when (text) {
            "q", "\u0003" -> quit()
            "j", "\r", "\n", "\u001B[B" -> scroll(1)
            "k", "\u001B[A" -> scroll(-1)
            " ", "f", "\u001B[6~" -> scroll(pageRows)
            "b", "\u001B[5~" -> scroll(-pageRows)
            "d" -> scroll(maxOf(1, pageRows / 2))
            "u" -> scroll(-maxOf(1, pageRows / 2))
            "g" -> { top = 0; draw() }
            "G" -> { top = maxTop; draw() }
        }
    }

    override fun resize(rows: Int, columns: Int) {
        this.rows = rows
        this.columns = columns
        rewrap()
        top = minOf(top, maxTop)
        draw()
    }

    /** Rows available to content — everything above the status bar. */
    private val pageRows: Int get() = maxOf(1, rows - 1)
    private val maxTop: Int get() = maxOf(0, wrapped.size - pageRows)

    private fun scroll(delta: Int) {
        val target = minOf(maxTop, maxOf(0, top + delta))
        if (target == top) return
        top = target
        draw()
    }

    private fun rewrap() {
        val out = ArrayList<String>(lines.size)
        for (line in lines) {
            if (line.length <= columns || columns <= 0) { out.add(line); continue }
            var rest = line
            while (rest.length > columns) {
                out.add(rest.substring(0, columns))
                rest = rest.substring(columns)
            }
            out.add(rest)
        }
        wrapped = if (out.isEmpty()) listOf("") else out
    }

    private fun draw() {
        val io = this.io ?: return
        val out = StringBuilder("\u001B[H")
        for (row in 0 until pageRows) {
            val index = top + row
            out.append("\u001B[2K")
            if (index < wrapped.size) out.append(wrapped[index])
            out.append("\r\n")
        }
        val bottom = minOf(top + pageRows, wrapped.size)
        val percent = if (maxTop == 0) 100 else Math.round(top.toDouble() / maxTop * 100).toInt()
        var status = " $title  ${top + 1}-$bottom/${wrapped.size}  $percent%  j/k space/b g/G q"
        if (status.length > columns) status = status.substring(0, columns)
        status += " ".repeat(maxOf(0, columns - status.length))
        out.append("\u001B[7m").append(status).append("\u001B[27m")
        io.write(out.toString())
    }

    private fun quit() {
        io?.write("\u001B[?25h\u001B[?1049l")
        io?.exit()
    }
}

/**
 * THE ENGAGEMENT RULE - when a streaming program becomes a screen program.
 *
 * A port of the static half of `NodeProgram` in swift/Mouse/TerminalPrograms.swift. It lives
 * here, in the platform-free module, for the same reason the screen does: it is the decision a
 * terminal makes about its own two surfaces, it is subtle enough to have caused a real bug on
 * iOS, and a harness must be able to drive it without an engine underneath.
 *
 * The rule (architecture - the two-surface terminal depends on it): output stays in the
 * SCROLLBACK until the program does something only a screen-oriented program does -
 *   1. switches to the alternate screen (`ESC[?1049h` and friends - vim, less), or
 *   2. asks for raw keystrokes (`stdin.setRawMode(true)` - every TUI framework), or
 *   3. moves the cursor UP over output it already wrote (CUU `ESC[nA`, CPL `ESC[nF`,
 *      RI `ESC M`) - the inline-repaint idiom of ink and logUpdate, which never touch the alt
 *      screen and may repaint before enabling raw mode.
 * From that moment the grid takes over. A line-streaming command never does any of the three,
 * so its output belongs to - and stays in - the scrollback.
 *
 * Rule 3 is the one that was missing on iOS, and its absence is what drew an ink UI as a pile of
 * text at the bottom of the phone's terminal while keystrokes repainted an invisible screen.
 *
 * Rule 2 is NOT decided here: raw mode is reported by the engine, not read out of the output
 * stream, so it belongs to the runtime half. That half - the engine's delivery channel, its
 * ordering contract, and the live grid shadow kept while still in transcript mode - arrives with
 * the Node layer's launch path, and `verify/tuinline` is the integration gate for it. What is
 * here is the decision logic, gated on its own.
 */
object TerminalEngagement {
    /**
     * The output half of the rule: an alt-screen switch, or upward cursor motion. Going back UP
     * to rewrite rows already written is repainting, and repainting is what a screen is for.
     *
     * Deliberately NOT triggers: clear-screen forms (watchers clear the transcript and stream
     * on), CR-only spinners (single line, no motion), and cursor-forward/down (progress
     * formatting within a line).
     */
    fun asksForScreen(text: String): Boolean {
        if (text.contains("\u001B[?1049h") || text.contains("\u001B[?1047h") ||
            text.contains("\u001B[?47h")
        ) {
            return true
        }
        // A tiny CSI walk rather than `contains`: the count parameter is arbitrary
        // (`ESC[A`, `ESC[1A`, `ESC[12A`), so the FINAL byte is what identifies the sequence.
        var index = 0
        while (index < text.length) {
            val character = text[index]
            index += 1
            if (character != '\u001B' || index >= text.length) continue
            val kind = text[index]
            index += 1
            if (kind == 'M') return true // RI - reverse index
            if (kind != '[') continue
            while (index < text.length) {
                val byte = text[index]
                index += 1
                if (byte.code < 0x40 || byte.code > 0x7e) continue // still parameters
                if (byte == 'A' || byte == 'F') return true // CUU / CPL
                break
            }
        }
        return false
    }

    /**
     * `ESC[2J` / `ESC[3J` (erase display, and the scrollback with it), `ESC c` (full reset), and
     * `ESC[J` / `ESC[0J` - erase from the cursor DOWN, which is how readline's `clearScreenDown`
     * clears and therefore how vite, nodemon and every watcher clear: home the cursor, erase
     * below. In a transcript there is nothing below, so it means the same thing.
     */
    fun clearsScreen(text: String): Boolean =
        text.contains("\u001B[2J") || text.contains("\u001B[3J") || text.contains("\u001Bc") ||
            text.contains("\u001B[0J") || text.contains("\u001B[J")

    /**
     * Drop ANSI escape sequences (CSI, OSC, and two-byte ESC forms) and carriage returns - the
     * scrollback is plain text.
     */
    fun strippingEscapes(text: String): String {
        val result = StringBuilder(text.length)
        var index = 0
        while (index < text.length) {
            val character = text[index]
            index += 1
            if (character == '\r') continue
            if (character != '\u001B') { result.append(character); continue }
            if (index >= text.length) break
            val kind = text[index]
            index += 1
            if (kind == '[') {
                // CSI: parameters and intermediates end at a final byte @-~.
                while (index < text.length) {
                    val byte = text[index]
                    index += 1
                    if (byte.code in 0x40..0x7e) break
                }
            } else if (kind == ']') {
                // OSC: runs to BEL or ESC backslash.
                var previous = kind
                while (index < text.length) {
                    val byte = text[index]
                    index += 1
                    if (byte.code == 0x7) break
                    if (previous == '\u001B' && byte == '\\') break
                    previous = byte
                }
            }
            // Two-byte forms (ESC =, ESC >, ...): the kind byte itself is consumed.
        }
        return result.toString()
    }
}

/**
 * The scrollback side of a streaming program: line-buffers its output and emits complete lines
 * with escapes stripped.
 *
 * Ported from `NodeProgram`'s transcript machinery. Two behaviours here are not obvious and both
 * were bugs on iOS first:
 *  - a line that was ENTIRELY escapes is NOT a blank line. A cursor move is not something a
 *    terminal prints, and dropping the distinction put two dozen empty rows above vite's banner,
 *    which clears the screen before writing it.
 *  - a clear-screen escape CLEARS the transcript. Every watcher clears before each run, and a
 *    terminal that ignores it shows the old output above the new.
 */
class TranscriptBuffer(
    private val emit: (text: String, isError: Boolean) -> Unit,
    private val clear: () -> Unit = {},
) {
    private val pending = StringBuilder()
    private var pendingIsError = false

    /** Feed one chunk of program output. */
    fun receive(text: String, isError: Boolean) {
        if (pendingIsError != isError) flush()
        pendingIsError = isError
        pending.append(text)
        while (true) {
            val newline = pending.indexOf("\n")
            if (newline < 0) break
            val line = pending.substring(0, newline)
            pending.delete(0, newline + 1)
            emitLine(line, isError)
        }
    }

    /** Emit whatever is still waiting for its newline - at engagement, and at exit. */
    fun flush() {
        if (pending.isEmpty()) return
        val line = pending.toString()
        pending.setLength(0)
        emitLine(line, pendingIsError)
    }

    private fun emitLine(line: String, isError: Boolean) {
        if (TerminalEngagement.clearsScreen(line)) clear()
        val text = TerminalEngagement.strippingEscapes(line)
        if (text.isEmpty() && line.isNotEmpty() && line.contains('\u001B')) return
        emit(text, isError)
    }
}
