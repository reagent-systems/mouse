package com.reagentsystems.mouse.terminal

import java.text.BreakIterator

/**
 * A terminal SCREEN: the second thing a terminal can be.
 *
 * The scrollback (the session's line list) is a transcript — an append-only list of what was
 * said. That's the right model for a shell, and the wrong one for `vim`, `htop`, or an agent
 * CLI with a live input line: those programs don't append, they *draw*, addressing a fixed grid
 * by row and column and repainting cells in place.
 *
 * So a real terminal is two modes. Programs switch to this one with the alt-screen sequence
 * (`ESC [ ? 1049 h`), draw for as long as they run, and switch back — which is why `vim` leaves
 * your shell history undisturbed when it exits.
 *
 * Platform-free by design (no Compose, no `android.*`), so it verifies headlessly against a
 * real terminal's behaviour. Colors are declared as data (`AnsiColor`); mapping them to
 * something drawable is the view layer's job.
 *
 * Scope: the VT100/xterm subset real programs actually emit — cursor motion, erase, insert and
 * delete of lines and characters, scroll regions, SGR attributes, 256-color and truecolor. Not
 * implemented (and deliberately so): character sets, double-width lines, mouse reporting,
 * sixel graphics.
 *
 * This is a faithful re-implementation of `swift/Mouse/TerminalScreen.swift`, not a bridge
 * (AGENTS.md invariant #5). Where the languages differ the semantics do not:
 *  - a Swift `Character` (grapheme cluster) is a `String` here, because a Kotlin `Char` is a
 *    UTF-16 code unit and cannot hold an emoji;
 *  - Swift structs are values, so `normalGrid = grid` copies. Kotlin lists are references, so
 *    the same lines deep-copy explicitly. `CellStyle`/`TerminalCell` are immutable data
 *    classes, which restores value semantics for the cells themselves;
 *  - `Sendable` and `@MainActor` have no Kotlin equivalent. This type is main-thread state,
 *    like its iOS twin; the Compose layer owns that discipline.
 */

/**
 * A color as ANSI expresses it. `Default` means "the terminal's own foreground/background",
 * which is what keeps an ordinary program monochrome inside Mouse's black container.
 */
sealed interface AnsiColor {
    data object Default : AnsiColor

    /** 0–7 standard, 8–15 bright, 16–231 the 6×6×6 cube, 232–255 grayscale. */
    data class Indexed(val index: Int) : AnsiColor

    /** 0–255 per channel. Swift stores `UInt8`; Kotlin has no ergonomic unsigned byte, so the
     *  clamp happens where the SGR parameters are read. */
    data class Rgb(val red: Int, val green: Int, val blue: Int) : AnsiColor
}

/** Everything SGR can say about one cell. */
data class CellStyle(
    val foreground: AnsiColor = AnsiColor.Default,
    val background: AnsiColor = AnsiColor.Default,
    val bold: Boolean = false,
    val dim: Boolean = false,
    val italic: Boolean = false,
    val underline: Boolean = false,
    /** Swap foreground and background at draw time — how TUIs draw selections and status bars. */
    val inverse: Boolean = false,
) {
    companion object {
        val plain = CellStyle()
    }
}

data class TerminalCell(
    val character: String = " ",
    val style: CellStyle = CellStyle.plain,
    /**
     * The right-hand column of a two-column character. It carries no glyph of its own — the
     * wide character to its left is drawn across both — but it must occupy the cell so the
     * grid's arithmetic stays honest.
     */
    val isContinuation: Boolean = false,
) {
    companion object {
        val blank = TerminalCell()
    }
}

/**
 * The grid, the cursor, and the rules for moving both.
 *
 * Coordinates are 0-based internally; ANSI is 1-based on the wire, and the parser converts.
 * Every mutation clamps to the grid, because a program that walks off the edge should be
 * pinned, not crash the app.
 */
class TerminalScreen(rows: Int = 24, columns: Int = 80) {
    var rows: Int = maxOf(1, rows)
        private set
    var columns: Int = maxOf(1, columns)
        private set
    var grid: MutableList<MutableList<TerminalCell>> = MutableList(maxOf(1, rows)) {
        MutableList(maxOf(1, columns)) { TerminalCell.blank }
    }
        private set

    var cursorRow = 0
        private set
    var cursorColumn = 0
        private set
    var cursorVisible = true

    /** The current drawing attributes — SGR mutates this, and every printed cell copies it. */
    var style: CellStyle = CellStyle.plain

    /**
     * The scrolling region (DECSTBM), inclusive. Scrolling and newlines act only inside it,
     * which is how a TUI keeps a header or status bar pinned while content scrolls beneath.
     */
    private var scrollTop = 0
    private var scrollBottom = this.rows - 1

    private var savedCursor: SavedCursor? = null

    private data class SavedCursor(val row: Int, val column: Int, val style: CellStyle)

    /**
     * Set once a program requests the alt screen; the view uses it to decide which of the two
     * modes to render.
     */
    var isAlternate = false
        private set

    /**
     * DECCKM: while set (`ESC[?1h`), the arrow/Home/End keys encode as SS3 (`ESC O A`)
     * instead of CSI (`ESC[A`). Readline and vim enable it and bind the application form —
     * the keyboard layer reads this to encode arrows the way the running program expects.
     */
    var applicationCursorKeys = false
        private set

    /**
     * Bracketed paste (`ESC[?2004h`): while set, pasted text reaches the program wrapped in
     * `ESC[200~` … `ESC[201~`, so a multi-line paste is one atomic block instead of a burst
     * of Enters. Agent CLIs and editors enable it precisely so a pasted snippet doesn't
     * submit line-by-line.
     */
    var bracketedPaste = false
        private set

    /** True when anything changed since the last render — lets the view skip untouched frames. */
    var isDirty = true
        private set

    fun markClean() {
        isDirty = false
    }

    // MARK: - Geometry

    /**
     * Re-fit to a new size. Content is preserved top-left; the cursor is clamped. (Real
     * terminals reflow wrapped lines here; we don't, because on a phone the size changes on
     * rotation and reflowing a TUI's own layout would corrupt it — the program will repaint.)
     */
    fun resize(rows: Int, columns: Int) {
        val newRows = maxOf(1, rows)
        val newColumns = maxOf(1, columns)
        if (newRows == this.rows && newColumns == this.columns) return
        val fresh = MutableList(newRows) { MutableList(newColumns) { TerminalCell.blank } }
        for (row in 0 until minOf(this.rows, newRows)) {
            for (column in 0 until minOf(this.columns, newColumns)) {
                fresh[row][column] = grid[row][column]
            }
        }
        grid = fresh
        this.rows = newRows
        this.columns = newColumns
        scrollTop = 0
        scrollBottom = newRows - 1
        cursorRow = minOf(cursorRow, newRows - 1)
        cursorColumn = minOf(cursorColumn, newColumns - 1)
        isDirty = true
    }

    // MARK: - Alt screen

    /** The normal screen, held while a full-screen program owns the alternate one. */
    private var normalGrid: MutableList<MutableList<TerminalCell>>? = null
    private var normalCursor: SavedCursor? = null

    /** `ESC [ ? 1049 h` — save the normal screen and the cursor, then hand over a cleared one. */
    fun enterAlternate() {
        if (isAlternate) return
        isAlternate = true
        // Swift's array copy is a value copy; Kotlin's would alias, so the rows are cloned.
        normalGrid = grid.mapTo(mutableListOf()) { it.toMutableList() }
        normalCursor = SavedCursor(cursorRow, cursorColumn, style)
        clearAll()
        moveCursor(0, 0)
        isDirty = true
    }

    /**
     * `ESC [ ? 1049 l` — put the normal screen BACK, which is the whole point of the pair.
     * This used to clear instead of restoring, so quitting `less` or `top` left the terminal
     * blank rather than showing the work that was there before it launched.
     */
    fun leaveAlternate() {
        if (!isAlternate) return
        isAlternate = false
        // A resize while the alternate screen was up leaves the saved grid the wrong shape;
        // a cleared screen is the honest fallback there.
        val saved = normalGrid
        if (saved != null && saved.size == rows && saved.firstOrNull()?.size == columns) {
            grid = saved
        } else {
            clearAll()
        }
        val cursor = normalCursor
        if (cursor != null) {
            cursorRow = minOf(cursor.row, rows - 1)
            cursorColumn = minOf(cursor.column, columns - 1)
            style = cursor.style
        } else {
            moveCursor(0, 0)
        }
        normalGrid = null
        normalCursor = null
        isDirty = true
    }

    fun setApplicationCursorKeys(enabled: Boolean) {
        applicationCursorKeys = enabled
    }

    fun setBracketedPaste(enabled: Boolean) {
        bracketedPaste = enabled
    }

    // MARK: - Cursor

    fun moveCursor(row: Int, column: Int) {
        cursorRow = minOf(maxOf(0, row), rows - 1)
        cursorColumn = minOf(maxOf(0, column), columns - 1)
        isDirty = true
    }

    fun moveCursorBy(deltaRow: Int = 0, deltaColumn: Int = 0) {
        moveCursor(cursorRow + deltaRow, cursorColumn + deltaColumn)
    }

    // CUU/CUD stop at the scroll-region margin — but only when the cursor starts inside the
    // region; from outside it, the screen edge is the limit (xterm).

    fun cursorUp(count: Int) {
        val limit = if (cursorRow >= scrollTop) scrollTop else 0
        cursorRow = maxOf(cursorRow - maxOf(1, count), limit)
        cursorColumn = minOf(cursorColumn, columns - 1)
        isDirty = true
    }

    fun cursorDown(count: Int) {
        val limit = if (cursorRow <= scrollBottom) scrollBottom else rows - 1
        cursorRow = minOf(cursorRow + maxOf(1, count), limit)
        cursorColumn = minOf(cursorColumn, columns - 1)
        isDirty = true
    }

    fun saveCursor() {
        savedCursor = SavedCursor(cursorRow, cursorColumn, style)
    }

    fun restoreCursor() {
        val saved = savedCursor ?: return
        moveCursor(saved.row, saved.column)
        style = saved.style
    }

    fun setScrollRegion(top: Int, bottom: Int) {
        val clampedTop = minOf(maxOf(0, top), rows - 1)
        val clampedBottom = minOf(maxOf(0, bottom), rows - 1)
        if (clampedTop >= clampedBottom) return
        scrollTop = clampedTop
        scrollBottom = clampedBottom
        // xterm homes to the absolute top-left on DECSTBM, not the region top.
        moveCursor(0, 0)
    }

    fun resetScrollRegion() {
        scrollTop = 0
        scrollBottom = rows - 1
    }

    // MARK: - Writing

    /**
     * Print one character at the cursor, wrapping at the right edge. `character` is one
     * grapheme cluster (Swift's `Character`).
     */
    fun put(character: String) {
        val width = TerminalWidth.columns(character)
        // A zero-width character belongs to the grapheme already on the screen. It arrives here
        // alone because the parser walks code points, so attach it rather than letting it
        // consume a column.
        if (width == 0) {
            val target = if (cursorColumn > 0) cursorColumn - 1 else 0
            if (target < columns && !grid[cursorRow][target].isContinuation) {
                // A cell holds a whole grapheme cluster, so the mark is merged by rebuilding
                // the cluster from its text rather than mutated in place.
                val merged = grid[cursorRow][target].character + character
                if (isSingleGrapheme(merged)) {
                    grid[cursorRow][target] = grid[cursorRow][target].copy(character = merged)
                    isDirty = true
                }
            }
            return
        }
        if (cursorColumn >= columns) {
            cursorColumn = 0
            lineFeed()
        }
        // A two-column character cannot straddle the right edge: it wraps whole, as a real
        // terminal does, rather than being split across two lines.
        if (width == 2 && cursorColumn == columns - 1) {
            grid[cursorRow][cursorColumn] = TerminalCell(character = " ", style = style)
            cursorColumn = 0
            lineFeed()
        }
        clearWidePartner(cursorRow, cursorColumn)
        grid[cursorRow][cursorColumn] = TerminalCell(character = character, style = style)
        if (width == 2 && cursorColumn + 1 < columns) {
            clearWidePartner(cursorRow, cursorColumn + 1)
            grid[cursorRow][cursorColumn + 1] =
                TerminalCell(character = " ", style = style, isContinuation = true)
        }
        cursorColumn += width
        isDirty = true
    }

    /**
     * Overwriting either half of a two-column character destroys the whole thing, so the other
     * half has to go blank. Without this a grid accumulates orphans: a continuation cell with
     * nothing to its left, or a wide glyph whose partner now holds someone else's letter.
     */
    private fun clearWidePartner(row: Int, column: Int) {
        if (row >= grid.size || column >= columns) return
        if (grid[row][column].isContinuation) {
            if (column > 0) grid[row][column - 1] = TerminalCell(style = grid[row][column - 1].style)
        } else if (column + 1 < columns && grid[row][column + 1].isContinuation) {
            grid[row][column + 1] = TerminalCell(style = grid[row][column + 1].style)
        }
    }

    /** Down one row, scrolling the region when already at its bottom. */
    fun lineFeed() {
        if (cursorRow == scrollBottom) {
            scrollUp(1)
        } else if (cursorRow < rows - 1) {
            cursorRow += 1
        }
        isDirty = true
    }

    /**
     * Up one row, scrolling the region down when already at its top — the inverse of
     * `lineFeed`, emitted as `ESC M` (how `less` scrolls backward).
     */
    fun reverseIndex() {
        if (cursorRow == scrollTop) {
            scrollDown(1)
        } else if (cursorRow > 0) {
            cursorRow -= 1
        }
        isDirty = true
    }

    fun carriageReturn() {
        cursorColumn = 0
        isDirty = true
    }

    fun backspace() {
        if (cursorColumn > 0) cursorColumn -= 1
        isDirty = true
    }

    /** Advance to the next 8-column tab stop (the fixed default; DECTABSSTOPS isn't supported). */
    fun tab() {
        val next = ((cursorColumn / 8) + 1) * 8
        cursorColumn = minOf(next, columns - 1)
        isDirty = true
    }

    // MARK: - Scrolling

    fun scrollUp(count: Int) {
        if (count <= 0) return
        repeat(count) {
            grid.removeAt(scrollTop)
            grid.add(scrollBottom, MutableList(columns) { blankCell() })
        }
        isDirty = true
    }

    fun scrollDown(count: Int) {
        if (count <= 0) return
        repeat(count) {
            grid.removeAt(scrollBottom)
            grid.add(scrollTop, MutableList(columns) { blankCell() })
        }
        isDirty = true
    }

    // MARK: - Erasing

    /**
     * A blank that carries the current BACKGROUND — erasing inside a colored region must leave
     * the color behind, or TUIs get holes punched in their panels.
     */
    private fun blankCell(): TerminalCell =
        TerminalCell.blank.copy(style = CellStyle.plain.copy(background = style.background))

    fun clearAll() {
        grid = MutableList(rows) { MutableList(columns) { blankCell() } }
        isDirty = true
    }

    /** ED: 0 = cursor to end of screen, 1 = start of screen to cursor, 2/3 = all. */
    fun eraseInDisplay(mode: Int) {
        when (mode) {
            0 -> {
                eraseInLine(0)
                if (cursorRow + 1 < rows) {
                    for (row in (cursorRow + 1) until rows) {
                        grid[row] = MutableList(columns) { blankCell() }
                    }
                }
            }
            1 -> {
                eraseInLine(1)
                if (cursorRow > 0) {
                    for (row in 0 until cursorRow) {
                        grid[row] = MutableList(columns) { blankCell() }
                    }
                }
            }
            else -> clearAll()
        }
        isDirty = true
    }

    /** EL: 0 = cursor to end of line, 1 = start of line to cursor, 2 = whole line. */
    fun eraseInLine(mode: Int) {
        when (mode) {
            0 -> for (column in cursorColumn until columns) grid[cursorRow][column] = blankCell()
            1 -> for (column in 0..minOf(cursorColumn, columns - 1)) grid[cursorRow][column] = blankCell()
            else -> grid[cursorRow] = MutableList(columns) { blankCell() }
        }
        isDirty = true
    }

    // MARK: - Insert / delete

    // IL and DL both home the cursor to the first column (VT510: "the cursor moves to the
    // first column of the line").

    fun insertLines(count: Int) {
        if (cursorRow < scrollTop || cursorRow > scrollBottom) return
        repeat(maxOf(0, count)) {
            grid.removeAt(scrollBottom)
            grid.add(cursorRow, MutableList(columns) { blankCell() })
        }
        cursorColumn = 0
        isDirty = true
    }

    fun deleteLines(count: Int) {
        if (cursorRow < scrollTop || cursorRow > scrollBottom) return
        repeat(maxOf(0, count)) {
            grid.removeAt(cursorRow)
            grid.add(scrollBottom, MutableList(columns) { blankCell() })
        }
        cursorColumn = 0
        isDirty = true
    }

    // After printing into the last column the cursor rests AT `columns` (pending wrap), so
    // every in-line edit clamps it back onto the grid first.

    fun insertCharacters(count: Int) {
        val column = minOf(cursorColumn, columns - 1)
        repeat(maxOf(0, count)) {
            grid[cursorRow].removeAt(grid[cursorRow].size - 1)
            grid[cursorRow].add(column, blankCell())
        }
        isDirty = true
    }

    fun deleteCharacters(count: Int) {
        val column = minOf(cursorColumn, columns - 1)
        repeat(maxOf(0, count)) {
            grid[cursorRow].removeAt(column)
            grid[cursorRow].add(blankCell())
        }
        isDirty = true
    }

    fun eraseCharacters(count: Int) {
        val start = minOf(cursorColumn, columns - 1)
        val end = minOf(start + maxOf(1, count), columns)
        for (column in start until end) grid[cursorRow][column] = blankCell()
        isDirty = true
    }

    // MARK: - Reading (for the view and for tests)

    /** One row as plain text, trailing blanks trimmed. */
    fun text(row: Int): String {
        if (row < 0 || row >= rows) return ""
        return grid[row].joinToString("") { it.character }.trimEnd(' ')
    }

    /** The whole screen as plain text — the headless test's window into the grid. */
    val plainText: String
        get() = (0 until rows).joinToString("\n") { text(it) }

    private companion object {
        /**
         * Swift asks `merged.count == 1` — "did the mark fuse into one grapheme cluster?".
         * Kotlin has no grapheme-aware `count`, so the platform's cluster iterator answers the
         * same question.
         */
        fun isSingleGrapheme(text: String): Boolean {
            val iterator = BreakIterator.getCharacterInstance()
            iterator.setText(text)
            var clusters = 0
            while (iterator.next() != BreakIterator.DONE) {
                clusters += 1
                if (clusters > 1) return false
            }
            return clusters == 1
        }
    }
}

/**
 * Feeds text to a `TerminalScreen`, interpreting ANSI escape sequences.
 *
 * A byte-at-a-time state machine, because escape sequences arrive split across reads: a program
 * can emit `ESC [` in one write and `2J` in the next, and a parser that assumed whole sequences
 * would corrupt the screen. State persists between `feed` calls for exactly that reason.
 */
class AnsiParser(private val screen: TerminalScreen) {
    private enum class State {
        GROUND,
        ESCAPE,

        /** Inside `ESC [ … final`. */
        CSI,

        /** Inside `ESC ] … BEL/ST` (window title and friends — parsed, then discarded). */
        OSC,

        /** After `ESC O` (SS3): the single next byte is a cursor/function final. */
        SS3,
    }

    private var state = State.GROUND
    private var parameters = StringBuilder()
    private var intermediates = StringBuilder()
    private var oscBuffer = StringBuilder()

    /**
     * The reply path for terminal queries (DSR, DA, DECRQM): a real terminal answers on the
     * program's stdin, so a TUI that probes cursor position or feature support gets its
     * answer and proceeds instead of blocking. null when no one is driving stdin (the pyte
     * cross-check, static renders) — queries are then consumed silently, as before.
     */
    var respond: ((String) -> Unit)? = null

    /**
     * Iterates CODE POINTS, not `Char`s: a UTF-16 code unit cannot hold an emoji, and half a
     * surrogate pair reaching `put` would print a replacement glyph and mis-count the column.
     * (Swift iterates unicode scalars for the mirror-image reason — its grapheme segmentation
     * fuses `\r\n` into one Character that matches neither control, silently eating every CRLF.)
     */
    fun feed(text: String) {
        var index = 0
        while (index < text.length) {
            val codePoint = text.codePointAt(index)
            index += Character.charCount(codePoint)
            feed(codePoint)
        }
    }

    private fun feed(codePoint: Int) {
        when (state) {
            State.GROUND -> ground(codePoint)
            State.ESCAPE -> escape(codePoint)
            State.CSI -> csi(codePoint)
            State.OSC -> osc(codePoint)
            State.SS3 -> ss3(codePoint)
        }
    }

    private fun ground(codePoint: Int) {
        when (codePoint) {
            0x1B -> {
                state = State.ESCAPE
                parameters = StringBuilder()
                intermediates = StringBuilder()
            }
            '\n'.code -> screen.lineFeed()
            '\r'.code -> screen.carriageReturn()
            '\t'.code -> screen.tab()
            0x8 -> screen.backspace()
            0x7 -> Unit // bell: a phone shouldn't beep at you
            else -> {
                // Skip other C0 controls; print everything else (including full Unicode).
                if (codePoint < 0x20) return
                screen.put(String(Character.toChars(codePoint)))
            }
        }
    }

    private fun escape(codePoint: Int) {
        when (codePoint.toChar()) {
            '[' -> {
                state = State.CSI
                parameters = StringBuilder()
                intermediates = StringBuilder()
            }
            ']' -> {
                state = State.OSC
                oscBuffer = StringBuilder()
            }
            '7' -> {
                screen.saveCursor(); state = State.GROUND
            }
            '8' -> {
                screen.restoreCursor(); state = State.GROUND
            }
            'O' -> state = State.SS3 // SS3 — the application-cursor-key form (ESC O A/B/C/D/H/F)
            'M' -> {
                screen.reverseIndex(); state = State.GROUND
            }
            'c' -> {
                screen.clearAll(); screen.moveCursor(0, 0)
                screen.style = CellStyle.plain; screen.resetScrollRegion(); state = State.GROUND
            }
            '(', ')', '#', '%' -> {
                // Character-set selects: consume this and the next byte, ignore both.
                intermediates = StringBuilder().append(codePoint.toChar()); state = State.ESCAPE
            }
            else -> state = State.GROUND
        }
    }

    /**
     * SS3: one final byte after `ESC O`. The cursor/Home/End forms move the cursor exactly
     * like their CSI twins, so a program that draws in application-cursor mode positions the
     * same. Function-key finals (P–S) carry no screen action.
     */
    private fun ss3(codePoint: Int) {
        when (codePoint.toChar()) {
            'A' -> screen.cursorUp(1)
            'B' -> screen.cursorDown(1)
            'C' -> screen.moveCursorBy(deltaColumn = 1)
            'D' -> screen.moveCursorBy(deltaColumn = -1)
            'H' -> screen.moveCursor(0, 0)
            'F' -> screen.moveCursor(screen.cursorRow, screen.columns - 1)
            else -> Unit
        }
        state = State.GROUND
    }

    private fun csi(codePoint: Int) {
        val character = if (codePoint in 0..0xFFFF) codePoint.toChar() else ' '
        // Parameter bytes (digits, ';', and private markers like '?') accumulate.
        if (character in '0'..'9' || character == ';' || character == '?' ||
            character == '>' || character == '='
        ) {
            parameters.append(character)
            return
        }
        if (character == ' ' || character == '!' || character == '"' ||
            character == '$' || character == '\''
        ) {
            intermediates.append(character)
            return
        }
        dispatchCsi(character)
        state = State.GROUND
        parameters = StringBuilder()
        intermediates = StringBuilder()
    }

    private fun osc(codePoint: Int) {
        // Terminated by BEL, or by ST (`ESC \`) — the ESC is swallowed here and the backslash
        // ends it on the next byte.
        if (codePoint == 0x7) {
            state = State.GROUND
            oscBuffer = StringBuilder()
            return
        }
        if (codePoint == 0x1B) return
        if (codePoint == '\\'.code) {
            state = State.GROUND
            oscBuffer = StringBuilder()
            return
        }
        oscBuffer.appendCodePoint(codePoint)
    }

    // MARK: - CSI dispatch

    private val numericParameters: List<Int>
        get() = parameters.toString()
            .dropWhile { it == '?' || it == '>' || it == '=' }
            .split(";")
            .map { it.toIntOrNull() ?: 0 }

    private fun parameter(index: Int, fallback: Int): Int {
        val values = numericParameters
        if (index >= values.size) return fallback
        // An omitted parameter means "use the default", and ANSI writes omitted as empty or 0.
        return if (values[index] == 0) fallback else values[index]
    }

    private fun dispatchCsi(final: Char) {
        val isPrivate = parameters.startsWith("?")
        when (final) {
            'A' -> screen.cursorUp(parameter(0, 1))
            'B' -> screen.cursorDown(parameter(0, 1))
            'C' -> screen.moveCursorBy(deltaColumn = parameter(0, 1))
            'D' -> screen.moveCursorBy(deltaColumn = -parameter(0, 1))
            'E' -> {
                screen.cursorDown(parameter(0, 1)); screen.carriageReturn()
            }
            'F' -> {
                screen.cursorUp(parameter(0, 1)); screen.carriageReturn()
            }
            'G' -> screen.moveCursor(screen.cursorRow, parameter(0, 1) - 1)
            'H', 'f' -> screen.moveCursor(parameter(0, 1) - 1, parameter(1, 1) - 1)
            'J' -> screen.eraseInDisplay(numericParameters.firstOrNull() ?: 0)
            'K' -> screen.eraseInLine(numericParameters.firstOrNull() ?: 0)
            'L' -> screen.insertLines(parameter(0, 1))
            'M' -> screen.deleteLines(parameter(0, 1))
            'P' -> screen.deleteCharacters(parameter(0, 1))
            'X' -> screen.eraseCharacters(parameter(0, 1))
            '@' -> screen.insertCharacters(parameter(0, 1))
            'S' -> screen.scrollUp(parameter(0, 1))
            'T' -> screen.scrollDown(parameter(0, 1))
            'd' -> screen.moveCursor(parameter(0, 1) - 1, screen.cursorColumn)
            'r' -> {
                val values = numericParameters
                if (values.size >= 2 && values[0] > 0 && values[1] > 0) {
                    screen.setScrollRegion(values[0] - 1, values[1] - 1)
                } else {
                    screen.resetScrollRegion()
                }
            }
            's' -> screen.saveCursor()
            'u' -> screen.restoreCursor()
            'm' -> applySgr()
            'h' -> if (isPrivate) setMode(numericParameters, true)
            'l' -> if (isPrivate) setMode(numericParameters, false)
            'n' -> deviceStatusReport()
            'c' -> deviceAttributes()
            'p' -> if (intermediates.contains('$')) reportMode()
            else -> Unit // unimplemented sequences are consumed, never printed as garbage
        }
    }

    /**
     * DSR — the program asks the terminal's status. `ESC[5n` → OK, `ESC[6n` → the cursor's
     * 1-based position. The reply travels back on stdin, like a real tty.
     */
    private fun deviceStatusReport() {
        val reply = respond ?: return
        when (numericParameters.firstOrNull() ?: 0) {
            5 -> reply("\u001B[0n")
            6 -> reply("\u001B[${screen.cursorRow + 1};${screen.cursorColumn + 1}R")
            else -> Unit
        }
    }

    /**
     * DA — "what are you?" Primary (`ESC[c`) answers a VT102 with no options; secondary
     * (`ESC[>c`) answers a terminal-type/version triple. Enough for the feature checks
     * modern CLIs run before enabling colour or the alt screen.
     */
    private fun deviceAttributes() {
        val reply = respond ?: return
        if (parameters.startsWith(">")) {
            reply("\u001B[>0;10;0c") // "VT220-ish", version 10 — matches xterm's shape
        } else {
            reply("\u001B[?6c") // VT102
        }
    }

    /**
     * DECRQM — "is mode N set?" `ESC[?<n>$p` → `ESC[?<n>;<state>$y`, where state 1=set,
     * 2=reset. TUIs query synchronized output (2026) and bracketed paste (2004) this way to
     * decide whether to use them; answering "reset but recognized" (2) is the honest reply.
     */
    private fun reportMode() {
        val reply = respond ?: return
        val mode = numericParameters.firstOrNull() ?: return
        val state = when (mode) {
            1 -> if (screen.applicationCursorKeys) 1 else 2
            25 -> if (screen.cursorVisible) 1 else 2
            1049, 47, 1047 -> if (screen.isAlternate) 1 else 2
            2004 -> if (screen.bracketedPaste) 1 else 2
            2026 -> 2 // synchronized output: recognized, never persistently set
            else -> 0 // not recognized
        }
        reply("\u001B[?$mode;$state\$y")
    }

    private fun setMode(modes: List<Int>, enabled: Boolean) {
        for (mode in modes) {
            when (mode) {
                1 -> screen.setApplicationCursorKeys(enabled) // DECCKM
                25 -> screen.cursorVisible = enabled
                2004 -> screen.setBracketedPaste(enabled)
                1049, 47, 1047 -> if (enabled) screen.enterAlternate() else screen.leaveAlternate()
                else -> Unit // mouse reporting, focus events, etc: accepted and ignored
            }
        }
    }

    private fun applySgr() {
        val values = numericParameters.ifEmpty { listOf(0) }
        var index = 0
        while (index < values.size) {
            when (val code = values[index]) {
                0 -> screen.style = CellStyle.plain
                1 -> screen.style = screen.style.copy(bold = true)
                2 -> screen.style = screen.style.copy(dim = true)
                3 -> screen.style = screen.style.copy(italic = true)
                4 -> screen.style = screen.style.copy(underline = true)
                7 -> screen.style = screen.style.copy(inverse = true)
                22 -> screen.style = screen.style.copy(bold = false, dim = false)
                23 -> screen.style = screen.style.copy(italic = false)
                24 -> screen.style = screen.style.copy(underline = false)
                27 -> screen.style = screen.style.copy(inverse = false)
                in 30..37 -> screen.style = screen.style.copy(foreground = AnsiColor.Indexed(code - 30))
                39 -> screen.style = screen.style.copy(foreground = AnsiColor.Default)
                in 40..47 -> screen.style = screen.style.copy(background = AnsiColor.Indexed(code - 40))
                49 -> screen.style = screen.style.copy(background = AnsiColor.Default)
                in 90..97 -> screen.style = screen.style.copy(foreground = AnsiColor.Indexed(code - 90 + 8))
                in 100..107 -> screen.style = screen.style.copy(background = AnsiColor.Indexed(code - 100 + 8))
                38, 48 -> {
                    // Extended color: `38;5;n` (indexed) or `38;2;r;g;b` (truecolor).
                    if (index + 1 >= values.size) {
                        index = values.size
                    } else {
                        val isForeground = code == 38
                        val kind = values[index + 1]
                        if (kind == 5 && index + 2 < values.size) {
                            val color = AnsiColor.Indexed(values[index + 2])
                            screen.style = if (isForeground) screen.style.copy(foreground = color)
                            else screen.style.copy(background = color)
                            index += 2
                        } else if (kind == 2 && index + 4 < values.size) {
                            val color = AnsiColor.Rgb(
                                values[index + 2].coerceIn(0, 255),
                                values[index + 3].coerceIn(0, 255),
                                values[index + 4].coerceIn(0, 255),
                            )
                            screen.style = if (isForeground) screen.style.copy(foreground = color)
                            else screen.style.copy(background = color)
                            index += 4
                        } else {
                            index = values.size
                        }
                    }
                }
                else -> Unit
            }
            index += 1
        }
    }
}
