package com.reagentsystems.mouse

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.ui.Alignment
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
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
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

    /** Returns false if refused (already running). */
    fun run(raw: String, scope: CoroutineScope, workspace: Workspace?): Boolean {
        if (isRunning) return false
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
        if (!isRunning) return
        append("^C", Line.Kind.COMMAND)
        runningJob?.cancel()
    }

    private fun runMsh(command: String, scope: CoroutineScope, workspace: Workspace?) {
        val context = MouseShell.Context(
            root = root,
            markModified = { workspace?.markModified(it) },
            openFile = { /* set on the deck by the caller wiring */ pendingOpen = it },
            clear = { lines.clear() },
            emit = { append(it.text, if (it.isError) Line.Kind.ERROR else Line.Kind.OUTPUT) },
        )
        isRunning = true
        runningJob = scope.launch {
            val (outputs, echo) = msh.execute(command, context)
            if (echo != null) append("$prompt $echo", Line.Kind.COMMAND)
            for (o in outputs) append(o.text, if (o.isError) Line.Kind.ERROR else Line.Kind.OUTPUT)
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
        LazyColumn(state = listState, modifier = Modifier.weight(1f)) {
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
        Row {
            BasicText(terminal.prompt, style = TextStyle(fontFamily = mono, fontSize = Theme.codeSize, color = Theme.secondary))
            BasicTextField(
                value = field,
                onValueChange = { new ->
                    // While a command runs, any keypress interrupts it (input is refused anyway).
                    if (terminal.isRunning) { terminal.interrupt() } else field = new
                },
                singleLine = true,
                textStyle = TextStyle(fontFamily = mono, fontSize = Theme.codeSize, color = Theme.onContainer),
                cursorBrush = SolidColor(Theme.onContainer),
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Send),
                keyboardActions = KeyboardActions(onSend = {
                    if (terminal.run(field.text, scope, workspace)) field = TextFieldValue("")
                }),
                modifier = Modifier.padding(start = 6.dp).fillMaxWidth(),
            )
        }
    }
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
