package com.reagentsystems.mouse.nodehost

import com.reagentsystems.mouse.terminal.TerminalEngagement
import com.reagentsystems.mouse.terminal.TerminalProgram
import com.reagentsystems.mouse.terminal.TerminalProgramIO
import com.reagentsystems.mouse.terminal.TranscriptBuffer

/**
 * A running Node program, hosted as a terminal program. The T↔G join: phase T's screen meets
 * phase G's engine, which is the pair leg (c) needs and the reason the engagement rule was
 * ported and gated with nothing calling it.
 *
 * ## Two modes, and the program picks
 *
 * `node build.js` prints lines; `npx create-vite` draws. Neither announces which it is, so the
 * program starts in TRANSCRIPT mode — output goes to the scrollback as plain lines — and becomes
 * a SCREEN program the moment it does one of the three things only a screen program does: the
 * alternate screen, raw mode, or moving the cursor UP. [TerminalEngagement] is that rule, shared
 * with iOS and gated by `:screencheck`.
 *
 * Every write is fed to the grid as a live shadow even while streaming, so at the moment of
 * engagement the screen already holds what the program drew and a cursor-up lands on the rows it
 * meant. That is the same discipline `NodeProgram.swift` records.
 *
 * ## Ordering is the contract
 *
 * The engine emits stdout, stderr and mode changes from the WebView's own threads, and they must
 * be applied in the order produced: a frame applied after a newer one leaves the display showing
 * the stale frame, which reads as a TUI that freezes. Everything here arrives already hopped to
 * the main thread by [NodeWebView] — one looper, so arrival order is application order — and the
 * one thing that does not is [onRawMode], which is posted to the same looper for the same reason.
 */
class NodeProgram(
    override val title: String,
    private val engine: NodeWebView,
    /** Called per complete line while in transcript mode. Escapes are already stripped. */
    transcript: (String, Boolean) -> Unit,
    /**
     * A clear-screen escape while STREAMING. vite, nodemon and every watcher clear before each
     * run, and a scrollback that ignores it shows the old output above the new.
     */
    clearTranscript: () -> Unit = {},
    private val onExit: (Int) -> Unit,
) : TerminalProgram {

    override var rendersScreen: Boolean = false
        private set

    private var io: TerminalProgramIO? = null
    private val buffer = TranscriptBuffer(emit = transcript, clear = clearTranscript)

    /** Raw mode = keystrokes are bytes, ^C included; cooked mode = ^C is a signal. */
    private var rawMode = false

    override fun start(io: TerminalProgramIO) {
        this.io = io
        engine.onRawMode = { raw ->
            rawMode = raw
            if (raw) engage(io)
        }
        engine.resizeTty(io.rows, io.columns)
    }

    /**
     * One chunk of program output. Called on the main thread by the host.
     *
     * The grid is fed FIRST and always — see the class note on the live shadow — and the
     * transcript only receives what has not engaged yet.
     */
    fun write(text: String, isError: Boolean) {
        val io = this.io ?: return
        io.write(onlcr(text))
        if (!rendersScreen && TerminalEngagement.asksForScreen(text)) {
            engage(io)
            return
        }
        if (!rendersScreen) buffer.receive(text, isError)
    }

    /** The program exited: flush whatever never got its newline, then let the host tear down. */
    fun finished(code: Int) {
        if (!rendersScreen) buffer.flush()
        engine.onRawMode = null
        onExit(code)
        io?.exit?.invoke()
    }

    private fun engage(io: TerminalProgramIO) {
        if (rendersScreen) return
        rendersScreen = true
        // Through the CALLBACK, never by letting the host re-read the property: the flip is
        // invisible to Compose observation because this is a plain object, and a terminal that
        // keyed its display on the property alone kept showing the scrollback while a TUI drew
        // on a grid nobody rendered. That was the iOS phone bug, and Compose inherits it the
        // same way — `programOnScreen` is the snapshot state that matters.
        io.modeChanged()
    }

    override fun input(text: String) {
        // The terminal discipline: cooked-mode ^C is a signal (handlers, or death), raw-mode ^C
        // is just a byte the program reads. A TUI in raw mode handles its own.
        if (text == "\u0003" && !rawMode) engine.interrupt() else engine.deliverInput(text)
    }

    override fun resize(rows: Int, columns: Int) {
        engine.resizeTty(rows, columns)
    }

    private companion object {
        /**
         * ONLCR: a bare `\n` (not already preceded by `\r`) becomes `\r\n`.
         *
         * The TTY's job, not the emulator's. A real pty maps NL→CR-NL on output, so a program
         * ending its lines with a bare `\n` — every `logUpdate`-style repaint, which is what
         * clack and ink do — lands each line at column 0. Without it the screen, correctly
         * xterm-faithful in treating LF as index, SHEARS THE FRAME DIAGONALLY: that is exactly
         * how create-vite's menu first rendered here, each row one column further right than the
         * last. We are the pty substitute, so the translation belongs here.
         *
         * A stray `\r\n` split across two writes yields a harmless `\r\r\n` — CR to column 0
         * is idempotent — so no cross-chunk state is needed.
         */
        fun onlcr(text: String): String {
            if (!text.contains('\n')) return text
            val result = StringBuilder(text.length + 8)
            var previous = '\u0000'
            for (ch in text) {
                if (ch == '\n' && previous != '\r') result.append('\r')
                result.append(ch)
                previous = ch
            }
            return result.toString()
        }
    }
}
