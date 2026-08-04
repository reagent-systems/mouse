package com.reagentsystems.mouse

import android.os.Handler
import com.reagentsystems.mouse.node.NodeProcessConfig
import com.reagentsystems.mouse.nodehost.NodeRunner
import android.os.Looper
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.ui.Alignment
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.withStyle
import androidx.compose.runtime.key
import androidx.compose.ui.unit.sp
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.unit.dp
import com.reagentsystems.mouse.terminal.AnsiColor
import com.reagentsystems.mouse.terminal.AnsiParser
import com.reagentsystems.mouse.terminal.CellStyle
import com.reagentsystems.mouse.terminal.TerminalKey
import com.reagentsystems.mouse.terminal.TerminalProgram
import com.reagentsystems.mouse.terminal.TerminalProgramIO
import com.reagentsystems.mouse.terminal.TerminalScreen
import com.reagentsystems.mouse.shell.MouseShell
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.BufferedWriter
import java.io.File

/**
 * The terminal session behind the container. Two engines behind the switcher chip:
 *   msh — the portable from-scratch shell (shared with iOS)
 *   sh  — the device's real /system/bin/sh, a persistent process (Android's platform advantage)
 * Mirrors `TerminalSession` in the Swift app, plus the real-process engine iOS can't have.
 */
class TerminalSession(val root: File) {
    enum class Engine { MSH, SH }

    data class Line(val text: String, val kind: Kind) { enum class Kind { COMMAND, OUTPUT, ERROR } }

    val lines = mutableStateListOf<Line>()
    var engine by mutableStateOf(Engine.MSH)
    var isRunning by mutableStateOf(false); private set

    /**
     * The full-screen program owning the terminal right now (`less`), or null at the prompt.
     * While set, every keystroke routes to the program — the foreground-process model.
     */
    var program by mutableStateOf<TerminalProgram?>(null); private set

    /**
     * True while the running program DRAWS ON THE GRID — the observable truth the view keys its
     * two modes on, never `program?.rendersScreen`. A Node program flips that property mid-run
     * on a plain object, so a view reading it directly keeps showing the scrollback while a TUI
     * draws on a grid nobody displays. That was the iOS phone bug; Compose would inherit it the
     * same way, because a plain field is not snapshot state.
     */
    var programOnScreen by mutableStateOf(false); private set

    /**
     * Whether the current program ever used the ALTERNATE screen. An alt-screen program (less)
     * restores the normal screen on exit — nothing to keep. An inline TUI leaves its last frame
     * on the normal screen, and a real terminal keeps that frame in history — see programExited.
     */
    private var programUsedAltScreen = false

    /** The grid a program draws into; its output feeds through [parser]. */
    val screen = TerminalScreen()

    /**
     * Bumped on every program write so Compose redraws the grid. `TerminalScreen` is deliberately
     * a plain engine, not snapshot state — nothing in it is observable, so this counter is the
     * only signal the renderer has.
     */
    var screenGeneration by mutableStateOf(0); private set

    private val parser = AnsiParser(screen)

    /** Last geometry the container measured; programs are born at this size. */
    private var gridRows = 24
    private var gridColumns = 80

    private val msh = MouseShell()
    private var runningJob: Job? = null
    private var systemShell: SystemShell? = null

    val prompt: String get() = when (engine) {
        Engine.MSH -> msh.prompt
        Engine.SH -> if (cwdLabel().isEmpty()) "~ $" else "~/${cwdLabel()} $"
    }
    private fun cwdLabel() = ""

    fun switchEngine() {
        engine = if (engine == Engine.MSH) Engine.SH else Engine.MSH
        append("[engine: ${if (engine == Engine.MSH) "msh — mouse shell" else "sh — system shell"}]", Line.Kind.OUTPUT)
    }

    /** Returns false if refused (already running, or a program holds the terminal). */
    fun run(raw: String, scope: CoroutineScope, workspace: Workspace?): Boolean {
        if (isRunning || program != null) return false
        val command = raw.trim()
        append("$prompt $command", Line.Kind.COMMAND)
        if (command.isEmpty()) return true
        when (engine) {
            Engine.MSH -> runMsh(command, scope, workspace)
            Engine.SH -> runSystem(command)
        }
        return true
    }

    /** Any keypress at the prompt interrupts a running command — the phone's Ctrl-C. */
    fun interrupt() {
        program?.let {
            // ^C is a keystroke to a program — it decides what to do.
            it.input("\u0003")
            return
        }
        if (!isRunning) return
        append("^C", Line.Kind.COMMAND)
        runningJob?.cancel()
    }

    // MARK: - Full-screen programs

    /**
     * Adopt a program: size the screen, hand it its IO, and give it the keyboard. Refused
     * (in the scrollback, honestly) if one is already running.
     */
    fun launch(program: TerminalProgram) {
        if (this.program != null) {
            append("${program.title}: a program is already running", Line.Kind.ERROR)
            return
        }
        screen.resize(gridRows, gridColumns)
        // A fresh program gets a fresh screen: leave any stranded alt screen, show the cursor,
        // drop DECCKM/bracketed paste, then RIS.
        parser.feed("\u001B[?1049l\u001B[?25h\u001B[?1l\u001B[?2004l\u001Bc")
        this.program = program
        programOnScreen = program.rendersScreen
        programUsedAltScreen = false
        screenGeneration += 1
        // Terminal query replies (DSR/DA/DECRQM) travel back to the program as keystrokes — the
        // same path a real tty answers on.
        parser.respond = { reply -> this.program?.input(reply) }
        program.start(
            TerminalProgramIO(
                rows = gridRows,
                columns = gridColumns,
                write = { text ->
                    onMain {
                        parser.feed(text)
                        if (screen.isAlternate) programUsedAltScreen = true
                        screenGeneration += 1
                    }
                },
                exit = { onMain { programExited() } },
                modeChanged = {
                    onMain {
                        programOnScreen = this.program?.rendersScreen ?: false
                        screenGeneration += 1
                    }
                },
            ),
        )
    }

    /** A keystroke while a program runs. Returns false when no program has the keyboard. */
    fun sendKey(text: String): Boolean {
        val program = program ?: return false
        program.input(text)
        return true
    }

    /**
     * A special key (arrow, Home/End, F-key…) while a program runs. Encoded HERE because the
     * arrows' form depends on DECCKM — a mode the screen owns, not the keyboard layer.
     */
    fun sendSpecialKey(key: TerminalKey, modifiers: TerminalKey.Modifiers = TerminalKey.Modifiers.none): Boolean {
        val program = program ?: return false
        program.input(key.encoded(modifiers, screen.applicationCursorKeys))
        return true
    }

    /**
     * Pasted text while a program runs, wrapped in the bracketed-paste markers when the program
     * asked for them, so a multi-line paste is one block rather than a burst of Enters.
     */
    fun sendPaste(text: String): Boolean {
        val program = program ?: return false
        if (screen.bracketedPaste) program.input("\u001B[200~$text\u001B[201~") else program.input(text)
        return true
    }

    /** The container's measured geometry; resizes the grid and tells the program (SIGWINCH). */
    fun setGridSize(rows: Int, columns: Int) {
        val r = maxOf(4, rows)
        val c = maxOf(20, columns)
        if (r == gridRows && c == gridColumns) return
        gridRows = r
        gridColumns = c
        val program = program ?: return
        screen.resize(r, c)
        screenGeneration += 1
        program.resize(r, c)
    }

    private fun programExited() {
        if (program == null) return
        // An inline TUI (never on the alt screen) leaves its last frame on the normal screen, and
        // on a real terminal that frame stays in history when the prompt returns. Ours does the
        // same. Alt-screen programs restored the normal screen instead — nothing of theirs to
        // keep, same as real less.
        if (programOnScreen && !programUsedAltScreen) {
            val rows = (0 until screen.rows).map { screen.text(it) }
            val last = rows.indexOfLast { it.isNotEmpty() }
            if (last >= 0) for (row in rows.take(last + 1)) append(row, Line.Kind.OUTPUT)
        }
        program = null
        programOnScreen = false
        parser.respond = null
        // A crashed-out program must not strand the terminal on the alt screen.
        if (screen.isAlternate) parser.feed("\u001B[?25h\u001B[?1049l")
        screenGeneration += 1
    }

    /**
     * The `@MainActor` discipline iOS gets from the compiler, done by hand. A program may write
     * from any thread (the Node layer will); everything it touches here is Compose snapshot
     * state, which must be mutated on the main thread.
     */
    private fun onMain(body: () -> Unit) {
        if (Looper.myLooper() == Looper.getMainLooper()) body() else mainHandler.post(body)
    }

    private val mainHandler = Handler(Looper.getMainLooper())

    /**
     * msh is a BLOCKING API — it lives in `:shell`, which is coroutine-free so `:shellcheck` can
     * gate it on a bare JVM — so it runs on `Dispatchers.IO` and everything it calls back into
     * Compose state goes through [onMain]. `isActive` is what [interrupt]'s `cancel()` reaches:
     * the shell polls it in loops and streaming commands, standing in for iOS's `Task.isCancelled`.
     */
    private fun runMsh(command: String, scope: CoroutineScope, workspace: Workspace?) {
        isRunning = true
        runningJob = scope.launch {
            val self = coroutineContext[Job]
            val context = MouseShell.Context(
                root = root,
                markModified = { onMain { workspace?.markModified(it) } },
                openFile = { /* set on the deck by the caller wiring */ pendingOpen = it },
                clear = { onMain { lines.clear() } },
                emit = { o -> onMain { appendStream(o.text, if (o.isError) Line.Kind.ERROR else Line.Kind.OUTPUT) } },
                runtimes = Runtimes.support,
                launchProgram = { p -> onMain { launch(p) } },
                // The engine. `NodeRunner` blocks this (IO) thread and drives the WebView on the
                // main one; msh's own `isActive` is what stops a dev server on a keystroke.
                runNode = Runtimes.appContext?.let { app ->
                    MouseShell.NodeRun { source, path, argv, environment, mounts, emit, title, interactive ->
                        NodeRunner.run(
                            context = app,
                            source = source,
                            path = path,
                            config = NodeProcessConfig(
                                argv = argv,
                                env = environment,
                                cwd = "/" + msh.cwd,
                                // A TTY is what makes a prompt library prompt. Without it every
                                // one of them takes its default and the menu never appears — which
                                // is exactly what `npx create-vite` did before this.
                                isTty = interactive,
                                ttyRows = gridRows,
                                ttyColumns = gridColumns,
                            ),
                            root = root,
                            mounts = mounts,
                            sink = { text, isError -> emit(MouseShell.Output(text, isError)) },
                            cancelled = { self?.isActive == false },
                            host = if (!interactive) null else { p -> onMain { launch(p) } },
                            title = title,
                        )
                    }
                },
                isActive = { self?.isActive != false },
            )
            val (outputs, echo) = withContext(Dispatchers.IO) { msh.execute(command, context) }
            flushStreams()
            if (echo != null) append("$prompt $echo", Line.Kind.COMMAND)
            for (o in outputs) append(o.text.trimEnd('\n'), if (o.isError) Line.Kind.ERROR else Line.Kind.OUTPUT)
            isRunning = false
        }
    }

    /** A file the msh `open` command asked to route to the viewer; the container drains it. */
    var pendingOpen: String? = null

    private fun runSystem(command: String) {
        val shell = systemShell ?: SystemShell(root) { append(it, Line.Kind.OUTPUT) }.also { systemShell = it }
        shell.send(command)
    }

    private fun append(text: String, kind: Line.Kind) {
        lines.add(Line(text, kind))
        while (lines.size > 500) lines.removeAt(0)
    }

    /**
     * A partial line, per stream, waiting for the newline that ends it.
     *
     * Program output is a BYTE STREAM, not a sequence of lines, and one `write` is not one line.
     * CPython's `print('python says', 42)` reaches the host as four writes — `python says`, a
     * space, `42`, `\n` — because that is how WASI's `fd_write` is called. Treating each as its
     * own line turned `python says 42` into four rows on screen, one of them blank.
     *
     * So writes accumulate here and are cut on `\n` only, with whatever has no newline yet held
     * back until it gets one. stdout and stderr buffer separately: they are separate streams and
     * interleaving their fragments would corrupt both.
     */
    private val pending = HashMap<Line.Kind, StringBuilder>()

    /** Append a chunk of stream output, breaking it into lines only where it really breaks. */
    private fun appendStream(text: String, kind: Line.Kind) {
        val buffer = pending.getOrPut(kind) { StringBuilder() }
        buffer.append(text)
        var cut = buffer.indexOf("\n")
        while (cut >= 0) {
            append(buffer.substring(0, cut), kind)
            buffer.delete(0, cut + 1)
            cut = buffer.indexOf("\n")
        }
    }

    /**
     * Flush what a stream never terminated. A program that exits after `process.stdout.write('x')`
     * with no newline still wrote `x`, and dropping it would lose real output — node prints it.
     */
    private fun flushStreams() {
        for (kind in listOf(Line.Kind.OUTPUT, Line.Kind.ERROR)) {
            val buffer = pending[kind] ?: continue
            if (buffer.isNotEmpty()) {
                append(buffer.toString(), kind)
                buffer.setLength(0)
            }
        }
    }

    fun destroy() { systemShell?.destroy() }
}

/** A persistent `/system/bin/sh` process with stdin held open — real shell state between commands. */
private class SystemShell(workingDir: File, private val onLine: (String) -> Unit) {
    private val process = ProcessBuilder("/system/bin/sh").directory(workingDir).redirectErrorStream(true).start()
    private val stdin: BufferedWriter = process.outputStream.bufferedWriter()

    init {
        Thread {
            process.inputStream.bufferedReader().forEachLine(onLine)
            onLine("[shell exited]")
        }.apply { isDaemon = true }.start()
    }

    fun send(command: String) {
        runCatching { stdin.write(command); stdin.newLine(); stdin.flush() }
            .onFailure { onLine("[shell gone: ${it.message}]") }
    }

    fun destroy() = process.destroy()
}

@Composable
fun TerminalContainer(deck: CarouselDeck) {
    val workspace = deck.workspace
    val mono = Theme.mono
    if (workspace == null) {
        Box(Modifier.fillMaxSize().padding(Theme.containerPadding)) {
            BasicText("open a repo in the Files container —\nthe terminal runs on the workspace",
                style = TextStyle(fontFamily = mono, fontSize = Theme.promptSize, color = Theme.metadata))
        }
        return
    }
    val terminal = remember(workspace.root.path) { deck.terminal(workspace) }
    val scope = rememberCoroutineScope()
    val density = LocalDensity.current
    val listState = rememberLazyListState()
    var field by remember { mutableStateOf(TextFieldValue("")) }

    LaunchedEffect(terminal.lines.size) {
        if (terminal.lines.isNotEmpty()) listState.scrollToItem(terminal.lines.size - 1)
    }
    // Drain msh `open` requests into the ring's viewer.
    LaunchedEffect(terminal) {
        snapshotFlow { terminal.lines.size }.collect {
            terminal.pendingOpen?.let { deck.openFile(it); terminal.pendingOpen = null }
        }
    }

    Column(Modifier.fillMaxSize().padding(Theme.containerPadding)) {
        // The keys a phone does not have. Android's soft keyboard has no arrows, no escape and
        // no tab — without this strip a menu renders perfectly and its selection cannot be
        // moved. At the top, so it never sits under the thumb reaching for the prompt.
        //
        // Gated on a program existing at all, not on it owning the SCREEN: a transcript-mode
        // program needs `canc` just as much.
        // The engine chip floats over the container's top-LEFT corner. The strip is right-aligned
        // and clears it; without a strip the first scrollback line would run underneath it, so
        // the same band is reserved either way.
        if (terminal.program != null) TerminalKeyStrip(terminal)
        else Spacer(Modifier.height(ActionChips.diameter))
        // Two modes, like a real terminal: the transcript (scrollback), or the SCREEN while a
        // full-screen program owns it. The measured geometry sizes the character grid either
        // way, so a program is born at the size it will draw into.
        Box(
            Modifier.weight(1f).fillMaxWidth().onSizeChanged { size ->
                with(density) {
                    terminal.setGridSize(
                        rows = (size.height.toDp() / TerminalCellMetrics.height).toInt(),
                        columns = (size.width.toDp() / TerminalCellMetrics.width).toInt(),
                    )
                }
            },
        ) {
            // Keyed on the session's OBSERVABLE flag, never on `program?.rendersScreen`.
            if (terminal.programOnScreen) {
                TerminalScreenGrid(terminal)
            } else {
                LazyColumn(state = listState, modifier = Modifier.fillMaxSize()) {
                    items(terminal.lines) { line ->
                        BasicText(line.text, style = TextStyle(
                            fontFamily = mono, fontSize = Theme.codeSize,
                            color = when (line.kind) {
                                TerminalSession.Line.Kind.COMMAND -> Theme.onContainer
                                TerminalSession.Line.Kind.OUTPUT -> Theme.secondary
                                TerminalSession.Line.Kind.ERROR -> Theme.failure
                            }))
                    }
                }
            }
        }
        Row {
            // While a program runs, its name stands where the prompt was.
            BasicText(terminal.program?.title ?: terminal.prompt,
                style = TextStyle(fontFamily = mono, fontSize = Theme.codeSize, color = Theme.secondary))
            // The field is seeded the moment a program takes over, and emptied when it leaves:
            // the sentinel is the mechanism above, and leaving it behind at the prompt would put
            // an invisible character at the head of the next command.
            LaunchedEffect(terminal.program != null) {
                field = if (terminal.program != null) {
                    TextFieldValue(PROGRAM_SENTINEL, selection = TextRange(PROGRAM_SENTINEL.length))
                } else {
                    TextFieldValue("")
                }
            }
            BasicTextField(
                value = field,
                onValueChange = { new ->
                    when {
                        // A program owns the keyboard: every character is a keystroke to it, and
                        // the field never accumulates a line the program has already consumed.
                        //
                        // It holds a SENTINEL rather than nothing, and that is what makes
                        // backspace reachable at all. An empty field has nothing to delete, so
                        // Compose fires no `onValueChange` for the key and the keystroke is lost
                        // — `npx create-vite` asks for a project name, and a name that cannot be
                        // corrected is a prompt that cannot be answered. With one invisible
                        // character parked in it, a deletion is always an EDIT, and an edit is an
                        // event. The sentinel is a zero-width space: it occupies the field
                        // without occupying the screen.
                        terminal.program != null -> {
                            val typed = new.text.removePrefix(PROGRAM_SENTINEL)
                            if (new.text.length < PROGRAM_SENTINEL.length) {
                                // The sentinel itself was deleted: that is the backspace.
                                terminal.sendKey("\u007f")
                            } else if (typed.isNotEmpty()) {
                                terminal.sendKey(typed)
                            }
                            field = TextFieldValue(
                                PROGRAM_SENTINEL,
                                selection = TextRange(PROGRAM_SENTINEL.length),
                            )
                        }
                        // While a command runs, any keypress interrupts it (input is refused anyway).
                        terminal.isRunning -> terminal.interrupt()
                        else -> field = new
                    }
                },
                singleLine = true,
                textStyle = TextStyle(fontFamily = mono, fontSize = Theme.codeSize, color = Theme.onContainer),
                cursorBrush = SolidColor(Theme.onContainer),
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Send),
                keyboardActions = KeyboardActions(onSend = {
                    // Return is Enter to a program, and "run this line" at the prompt.
                    if (terminal.sendKey("\r")) return@KeyboardActions
                    if (terminal.run(field.text, scope, workspace)) field = TextFieldValue("")
                }),
                modifier = Modifier.padding(start = 6.dp).fillMaxWidth(),
            )
        }
    }
}

/**
 * The terminal's character-cell geometry. The view and the session must agree on how many cells
 * fit, so both sides read these. Height is the line height the renderer forces on every row;
 * width is one "M" in the mono face at [Theme.codeSize] — measured once, at first use, because
 * a Compose text measurer is not available where the session lives.
 */
/**
 * The invisible character the input field holds while a program owns the keyboard, so that a
 * deletion is an edit Compose will report. See the routing in the field's `onValueChange`.
 */
private const val PROGRAM_SENTINEL = "\u200B"

object TerminalCellMetrics {
    val height = 15.dp
    val width = 7.2.dp
}

/**
 * The SCREEN renderer: rows of styled cells while a program owns the terminal. Redraws are
 * driven by `screenGeneration` — the grid itself is a plain engine, not snapshot state.
 * No gestures of its own — the gesture law: content gets taps and the keyboard, the shell keeps
 * the drags.
 */
@Composable
private fun TerminalScreenGrid(terminal: TerminalSession) {
    val generation = terminal.screenGeneration
    val screen = terminal.screen
    // The generation identifies the WHOLE grid, not just its observation. Reading it above
    // re-runs this composable, but each row is an AnnotatedString diffed by value, and a
    // transition redraw (cursor-up over several rows, erase, rewrite) can leave rows judged
    // unchanged. A terminal rebuilds its rows every frame anyway, so tying identity to the
    // generation is both correct and cheap: a new generation is a new screen. This is the iOS
    // `.id(screenGeneration)` fix, which took four rounds to find there.
    key(generation) {
        Column(Modifier.fillMaxSize()) {
            for (row in 0 until screen.rows) {
                BasicText(
                    text = rowText(screen, row),
                    style = TextStyle(fontFamily = Theme.mono, fontSize = Theme.codeSize),
                    maxLines = 1,
                    modifier = Modifier.height(TerminalCellMetrics.height),
                )
            }
        }
    }
}

/** One row as styled text: run-length batched, with the cursor cell inverted. */
private fun rowText(screen: TerminalScreen, row: Int): AnnotatedString = buildAnnotatedString {
    val cells = screen.grid[row]
    val showCursor = screen.cursorVisible && row == screen.cursorRow
    val cursorColumn = minOf(screen.cursorColumn, cells.size - 1)
    var index = 0
    while (index < cells.size) {
        val style = cells[index].style
        if (showCursor && index == cursorColumn) {
            withStyle(spanStyle(style.copy(inverse = !style.inverse))) {
                append(if (cells[index].isContinuation) "" else cells[index].character)
            }
            index += 1
            continue
        }
        // Run-length batching: consecutive cells sharing a style render as one chunk.
        val text = StringBuilder()
        val runStart = index
        while (index < cells.size && cells[index].style == style &&
            !(showCursor && index == cursorColumn)
        ) {
            // A continuation cell has no glyph: the wide character to its left is drawn across
            // both columns, so appending its placeholder would double the spacing.
            if (!cells[index].isContinuation) text.append(cells[index].character)
            index += 1
        }
        if (index == runStart) { index += 1; continue }
        withStyle(spanStyle(style)) { append(text.toString()) }
    }
}

private fun spanStyle(style: CellStyle): SpanStyle {
    var foreground = ansiColor(style.foreground) ?: Theme.onContainer
    var background = ansiColor(style.background)
    if (style.inverse) {
        val fg = foreground
        foreground = background ?: Theme.container
        background = fg
    }
    if (style.dim) foreground = foreground.copy(alpha = 0.55f)
    return SpanStyle(
        color = foreground,
        background = background ?: Color.Unspecified,
        fontStyle = if (style.italic) FontStyle.Italic else null,
        textDecoration = if (style.underline) TextDecoration.Underline else null,
    )
}

/** null means "the terminal's own default" — white text on the container's black. */
private fun ansiColor(ansi: AnsiColor): Color? = when (ansi) {
    is AnsiColor.Default -> null
    is AnsiColor.Rgb -> Color(ansi.red, ansi.green, ansi.blue)
    is AnsiColor.Indexed -> indexedColor(ansi.index)
}

/** The xterm 256-color table: 16 named, a 6×6×6 cube, a 24-step gray ramp. */
private fun indexedColor(index: Int): Color = when (index) {
    0 -> Color(0, 0, 0)
    1 -> Color(205, 49, 49)
    2 -> Color(13, 188, 121)
    3 -> Color(229, 229, 16)
    4 -> Color(36, 114, 200)
    5 -> Color(188, 63, 188)
    6 -> Color(17, 168, 205)
    7 -> Color(229, 229, 229)
    8 -> Color(102, 102, 102)
    9 -> Color(241, 76, 76)
    10 -> Color(35, 209, 139)
    11 -> Color(245, 245, 67)
    12 -> Color(59, 142, 234)
    13 -> Color(214, 112, 214)
    14 -> Color(41, 184, 219)
    15 -> Color(255, 255, 255)
    in 16..231 -> {
        val value = index - 16
        val steps = intArrayOf(0, 95, 135, 175, 215, 255)
        Color(steps[value / 36], steps[(value / 6) % 6], steps[value % 6])
    }
    in 232..255 -> { val gray = 8 + (index - 232) * 10; Color(gray, gray, gray) }
    else -> Theme.onContainer
}

/**
 * The keys a phone's keyboard does not have. Bare labels on their own row at the top of the
 * container — the same shape a container's commands take everywhere in the app, not chips.
 */
@Composable
private fun TerminalKeyStrip(terminal: TerminalSession) {
    // Words, not arrow glyphs, for the same reason.
    val keys = listOf(
        "up" to TerminalKey.Up,
        "down" to TerminalKey.Down,
        "left" to TerminalKey.Left,
        "right" to TerminalKey.Right,
        "esc" to TerminalKey.Escape,
        "tab" to TerminalKey.Tab,
    )
    Row(
        Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(12.dp, Alignment.End),
    ) {
        for ((label, key) in keys) {
            KeyStripControl(label) { terminal.sendSpecialKey(key) }
        }
        // Last, and the only one that is not a keystroke: it stops the program. On a real
        // terminal this is ^C, which a phone keyboard cannot type either.
        KeyStripControl("canc") { terminal.interrupt() }
    }
}

@Composable
private fun KeyStripControl(label: String, action: () -> Unit) {
    BasicText(
        label,
        style = TextStyle(fontFamily = Theme.mono, fontSize = Theme.codeSize, color = Theme.secondary),
        // A taller hit area than the 12sp glyph.
        modifier = Modifier.clickable { action() }.padding(vertical = 6.dp),
    )
}

/** The engine switcher: a small capsule in the terminal's top-left; tap to cycle engines. */
@Composable
fun TerminalEngineChip(deck: CarouselDeck) {
    val workspace = deck.workspace ?: return
    val terminal = remember(workspace.root.path) { deck.terminal(workspace) }
    Box(
        Modifier
            .padding(top = ActionChips.inset, start = ActionChips.inset + 8.dp)
            .height(22.dp)
            .border(1.dp, Theme.lessonStroke, CircleShape)
            .clickable { terminal.switchEngine() }
            .padding(horizontal = 8.dp),
    ) {
        BasicText(
            if (terminal.engine == TerminalSession.Engine.MSH) "msh" else "sh",
            style = TextStyle(fontFamily = Theme.mono, fontSize = 10.sp, color = Theme.secondary),
            modifier = Modifier.align(Alignment.Center),
        )
    }
}
