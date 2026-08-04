package com.reagentsystems.mouse.shell

import com.reagentsystems.mouse.packages.Json
import com.reagentsystems.mouse.packages.PackageManager
import com.reagentsystems.mouse.packages.RuntimeCatalog
import com.reagentsystems.mouse.packages.RuntimeStore
import com.reagentsystems.mouse.terminal.PagerProgram
import com.reagentsystems.mouse.terminal.TerminalProgram
import java.io.File
import java.net.HttpURLConnection
import java.net.InetAddress
import java.net.URL
import java.security.MessageDigest
import java.util.Base64

/**
 * `msh` — the same from-scratch POSIX shell as the iOS app (`Shell.swift`), ported to Kotlin so
 * both platforms share one shell.
 *
 *   quoting        'literal'  "expands $VARS"  \escapes
 *   variables      $NAME  ${NAME}  $?   export NAME=value   env / unset
 *   tilde & globs  ~  *  ?  [abc]   (globs match against the workspace)
 *   pipelines      cat file | grep x | wc -l
 *   redirection    cmd > file   cmd >> file   cmd < file
 *   sequencing     a ; b     a && b     a || b
 *   language       if/elif/else  for  while/until  case  functions  test/[
 *                  $(cmd)  `cmd`  $((arith))  ${x:-y}  set -e  eval / source / sh
 *   history        history   !!   !3
 *
 * [ShellLanguage] owns the grammar; this file owns execution. Commands are Kotlin built-ins
 * running against the workspace tree; stdout/stderr are strings flowing between them, so pipes and
 * redirection are exact. Paths are clamped to the workspace root — `..` cannot escape it.
 *
 * The API is BLOCKING, like `:packages` and for the same reason: this module must run on a bare
 * JVM so `:shellcheck` can gate it, which rules out kotlinx-coroutines. Callers wrap it in
 * `withContext(Dispatchers.IO)`, and hand cancellation in as [Context.isActive] — the stand-in for
 * `Task.isCancelled`, which is what stops a streaming `ping` on iOS.
 */
class MouseShell {

    /** Wiring to the app: filesystem root plus the side effects a shell can cause. */
    class Context(
        val root: File,
        val markModified: (String) -> Unit = {},
        val openFile: (String) -> Unit = {},
        val clear: () -> Unit = {},
        /**
         * Incremental output from STREAMING commands (ping's once-a-second lines). Streaming
         * happens only when a command runs solo — pipelines collect instead, so `ping -c 3 x |
         * grep seq` still works as strings.
         */
        val emit: (Output) -> Unit = {},
        /**
         * The language-runtime catalog and where installs live. Null in a harness with no app
         * around it, which is what makes `pkg` answer honestly instead of crashing.
         */
        val runtimes: RuntimeSupport? = null,
        /**
         * Hand a full-screen program the terminal. Null when nothing can host one (a harness, or
         * a command running mid-pipeline), which is why `less` falls back to `cat`.
         */
        val launchProgram: ((TerminalProgram) -> Unit)? = null,
        /**
         * Run a JavaScript program in the Node engine and answer its exit status. Null in a
         * harness, and in `:shellcheck` — which is the point of it being a hook at all: the engine
         * is a WebView, so `:shell` cannot see it and must not try.
         */
        val runNode: NodeRun? = null,
        /**
         * False once the user has interrupted the running command. Loops and streaming commands
         * poll it; it is this module's `Task.isCancelled`, supplied by the caller because a
         * coroutine-free module cannot ask a Job directly.
         */
        val isActive: () -> Boolean = { true },
    )

    data class Output(val text: String, val isError: Boolean)

    /** The catalog and the store, handed in together so `pkg` never reaches for a singleton. */
    class RuntimeSupport(val catalog: List<RuntimeCatalog.Entry>, val store: RuntimeStore)

    /**
     * The engine, as msh sees it: source in, exit status out, output as it happens.
     *
     * Deliberately not "give me a NodeWebView". The engine lives on the main thread and this
     * module is blocking and coroutine-free — the seam has to be a function that hides both facts,
     * or `:shell` stops being gateable against the real `/bin/sh`.
     *
     * [mounts] grafts real directories in at virtual prefixes, which is how an installed runtime
     * outside the workspace becomes visible to the script that runs it.
     */
    fun interface NodeRun {
        fun run(
            source: String,
            path: String,
            argv: List<String>,
            env: Map<String, String>,
            mounts: List<Pair<String, File>>,
            emit: (Output) -> Unit,
        ): Int
    }

    /** Current directory, relative to the root ("" = root). The prompt renders it. */
    var cwd = ""; private set
    var lastStatus = 0; private set
    val history = ArrayList<String>()
    private val env = hashMapOf("HOME" to "/", "USER" to "mouse", "SHELL" to "msh", "PWD" to "/")

    val prompt: String get() = (if (cwd.isEmpty()) "~" else "~/$cwd") + " $"

    // MARK: - Entry

    /**
     * Run one input line; returns what to print. The second element is set when history expansion
     * (`!!`) rewrote the line, so the session can echo what actually ran.
     */
    fun execute(rawLine: String, context: Context): Pair<List<Output>, String?> {
        var line = rawLine.trim()
        if (line.isEmpty()) return emptyList<Output>() to null

        var echo: String? = null
        expandHistory(line)?.let { (text, ok) ->
            if (!ok) return listOf(Output(text, true)) to null
            line = text
            echo = line
        }
        history.add(line)
        if (history.size > 200) history.subList(0, history.size - 200).clear()

        return runProgram(line, context, interactive = true) to echo
    }

    /**
     * Parse and evaluate a full program — a prompt line or an entire script. [interactive] gates
     * full-screen program launches and streaming; scripts and command substitutions run with it
     * off.
     */
    fun runProgram(source: String, context: Context, interactive: Boolean): List<Output> {
        val program: ShellNode
        try {
            program = ShellParser.parse(source)
        } catch (e: ShellParseError) {
            lastStatus = 2
            return listOf(Output("msh: ${e.message}", true))
        }
        val sink = Sink()
        val state = EvalState(context, sink, interactive)
        try {
            evaluate(program, state)
        } catch (control: Control) {
            when (control) {
                is Control.ExitShell -> lastStatus = control.status
                is Control.ReturnStatus -> lastStatus = control.status
                // break/continue outside a loop: ignored, like sh
                is Control.BreakLoop, is Control.ContinueLoop -> {}
            }
        } catch (e: ShellParseError) {
            lastStatus = 2
            sink.commandErr("msh: ${e.message}\n")
        } catch (e: Exception) {
            lastStatus = 1
            sink.commandErr("msh: ${e.message}\n")
        }
        return sink.outputs
    }

    // MARK: - History expansion (!! and !n)

    private fun expandHistory(line: String): Pair<String, Boolean>? {
        if (!line.startsWith("!")) return null
        if (line == "!!") return history.lastOrNull()?.let { it to true } ?: ("msh: no history yet" to false)
        val n = line.drop(1).toIntOrNull()
        if (n != null && n in 1..history.size) return history[n - 1] to true
        return "msh: no such history entry: $line" to false
    }

    // MARK: - Evaluation

    /** Defined functions, by name; the body is the parsed AST. */
    private val functions = HashMap<String, ShellNode>()

    /** Positional parameters: a stack — scripts and function calls push, `$1…$#` read the top. */
    private val positionals = ArrayList<MutableList<String>>()

    /** `$0` for the innermost running script. */
    private val scriptNames = ArrayList<String>()

    /** `local` bookkeeping: per-function saved values, restored on return. */
    private val localScopes = ArrayList<HashMap<String, String?>>()

    // set -e / -x / -o pipefail
    private var optionExitOnError = false
    private var optionTrace = false
    private var optionPipefail = false

    /**
     * Where pipeline output lands. The display sink turns each pipeline's stdout into one
     * scrollback [Output] (trailing newline trimmed, terminal-style); a capture sink (command
     * substitution, functions, compounds in pipelines) collects raw stdout and bubbles stderr up
     * to the display.
     */
    private class Sink {
        val outputs = ArrayList<Output>()
        var captureBuffer: StringBuilder? = null
        var errSink: Sink? = null

        companion object {
            fun capture(errorsTo: Sink) = Sink().apply {
                captureBuffer = StringBuilder()
                errSink = errorsTo
            }
        }

        val captured: String get() = captureBuffer?.toString() ?: ""

        fun commandOut(raw: String) {
            captureBuffer?.let { it.append(raw); return }
            val trimmed = raw.removeSuffix("\n")
            if (trimmed.isNotEmpty()) outputs.add(Output(trimmed, false))
        }

        fun commandErr(raw: String) {
            errSink?.let { it.commandErr(raw); return }
            val trimmed = raw.removeSuffix("\n")
            if (trimmed.isNotEmpty()) outputs.add(Output(trimmed, true))
        }
    }

    /** stdin as scripts see it: a cursor over text, so `read` consumes it line by line. */
    private class StdinBuffer(text: String) {
        private var remaining = text

        fun readLine(): String? {
            if (remaining.isEmpty()) return null
            val newline = remaining.indexOf('\n')
            if (newline < 0) {
                val line = remaining
                remaining = ""
                return line
            }
            val line = remaining.substring(0, newline)
            remaining = remaining.substring(newline + 1)
            return line
        }
    }

    private class EvalState(
        val context: Context,
        val sink: Sink,
        val interactiveAllowed: Boolean,
        val stdin: StdinBuffer? = null,
    ) {
        var depth = 0

        fun child(
            sink: Sink? = null,
            stdin: StdinBuffer? = this.stdin,
            interactive: Boolean? = null,
        ): EvalState {
            val state = EvalState(context, sink ?: this.sink, interactive ?: interactiveAllowed, stdin)
            state.depth = depth + 1
            return state
        }
    }

    /**
     * Non-local exits: `break`/`continue` unwind to their loop, `return` to its function, `exit` to
     * the program (or the enclosing `sh` script). Stack traces are suppressed — these are control
     * flow, thrown once per loop iteration, not errors anyone will debug from a trace.
     */
    private sealed class Control : RuntimeException(null, null, false, false) {
        class BreakLoop(val levels: Int) : Control()
        class ContinueLoop(val levels: Int) : Control()
        class ReturnStatus(val status: Int) : Control()
        class ExitShell(val status: Int) : Control()
    }

    private fun evaluate(node: ShellNode, state: EvalState, asCondition: Boolean = false) {
        if (!state.context.isActive()) throw Control.ExitShell(130)
        when (node) {
            is ShellNode.Sequence ->
                for (child in node.nodes) evaluate(child, state, asCondition)

            is ShellNode.AndOr -> {
                evaluate(node.first, state, asCondition = true)
                for ((op, child) in node.rest) {
                    if ((op == "&&" && lastStatus == 0) || (op == "||" && lastStatus != 0)) {
                        evaluate(child, state, asCondition = true)
                    }
                }
                errExitCheck(asCondition)
            }

            is ShellNode.Pipeline -> {
                runPipelineNode(node.commands, node.negated, state)
                errExitCheck(asCondition)
            }

            is ShellNode.Simple -> {
                val out = runSimple(
                    node.assignments, node.words, node.redirects,
                    pipedIn = "", pipelinePosition = PipelinePosition.SOLO, state = state,
                )
                state.sink.commandOut(out)
                errExitCheck(asCondition)
            }

            is ShellNode.IfClause -> {
                for ((condition, body) in node.branches) {
                    evaluate(condition, state, asCondition = true)
                    if (lastStatus == 0) {
                        evaluate(body, state, asCondition)
                        return
                    }
                }
                val elseBody = node.elseBody
                if (elseBody != null) evaluate(elseBody, state, asCondition) else lastStatus = 0
            }

            is ShellNode.WhileClause -> withRedirects(node.redirects, state) { inner ->
                var bodyStatus = 0
                while (true) {
                    if (!inner.context.isActive()) throw Control.ExitShell(130)
                    evaluate(node.condition, inner, asCondition = true)
                    val proceed = if (node.until) lastStatus != 0 else lastStatus == 0
                    if (!proceed) break
                    try {
                        evaluate(node.body, inner)
                        bodyStatus = lastStatus
                    } catch (control: Control) {
                        when (control) {
                            is Control.BreakLoop -> {
                                if (control.levels > 1) throw Control.BreakLoop(control.levels - 1)
                                break
                            }
                            is Control.ContinueLoop -> {
                                if (control.levels > 1) throw Control.ContinueLoop(control.levels - 1)
                            }
                            else -> throw control
                        }
                    }
                }
                lastStatus = bodyStatus
            }

            is ShellNode.ForClause -> {
                val items: List<String> = node.words?.let { words ->
                    val expanded = ArrayList<String>()
                    for (word in words) expanded.addAll(expandWord(word, state))
                    expanded
                } ?: currentParams

                withRedirects(node.redirects, state) { inner ->
                    var bodyStatus = 0
                    loop@ for (item in items) {
                        if (!inner.context.isActive()) throw Control.ExitShell(130)
                        env[node.variable] = item
                        try {
                            evaluate(node.body, inner)
                            bodyStatus = lastStatus
                        } catch (control: Control) {
                            when (control) {
                                is Control.BreakLoop -> {
                                    if (control.levels > 1) throw Control.BreakLoop(control.levels - 1)
                                    break@loop
                                }
                                is Control.ContinueLoop -> {
                                    if (control.levels > 1) throw Control.ContinueLoop(control.levels - 1)
                                }
                                else -> throw control
                            }
                        }
                    }
                    lastStatus = bodyStatus
                }
            }

            is ShellNode.CaseClause -> {
                val value = expandNoSplit(node.subject, state)
                lastStatus = 0
                for (item in node.items) {
                    for (pattern in item.patterns) {
                        if (ShellPattern.matches(expandNoSplit(pattern, state), value)) {
                            evaluate(item.body, state, asCondition)
                            return
                        }
                    }
                }
            }

            is ShellNode.FunctionDef -> {
                functions[node.name] = node.body
                lastStatus = 0
            }

            is ShellNode.BraceGroup -> withRedirects(node.redirects, state) { inner ->
                evaluate(node.body, inner, asCondition)
            }
        }
    }

    private fun errExitCheck(asCondition: Boolean) {
        if (optionExitOnError && !asCondition && lastStatus != 0) throw Control.ExitShell(lastStatus)
    }

    /**
     * Applies compound-command redirects: `< file` becomes the stdin buffer `read` consumes;
     * `> file` captures the compound's stdout and writes it at the end.
     */
    private fun withRedirects(redirects: List<ShellRedirect>, state: EvalState, body: (EvalState) -> Unit) {
        var inner = state
        var outFile: Pair<String, Boolean>? = null
        var captureSink: Sink? = null
        for (redirect in redirects) {
            val target = expandNoSplit(redirect.target, inner)
            when (redirect.kind) {
                ShellRedirect.Kind.STDIN_READ -> {
                    val text = resolve(target, inner.context)?.file?.takeIf { it.isFile }?.readText()
                    if (text == null) {
                        inner.sink.commandErr("msh: can't read $target\n")
                        lastStatus = 1
                        return
                    }
                    inner = inner.child(stdin = StdinBuffer(text))
                }
                ShellRedirect.Kind.STDOUT_WRITE, ShellRedirect.Kind.STDOUT_APPEND -> {
                    val sink = Sink.capture(inner.sink)
                    captureSink = sink
                    outFile = target to (redirect.kind == ShellRedirect.Kind.STDOUT_APPEND)
                    inner = inner.child(sink = sink, interactive = false)
                }
            }
        }
        body(inner)
        if (outFile != null && captureSink != null) {
            write(captureSink.captured, outFile.first, outFile.second, inner.context)?.let {
                inner.sink.commandErr(it + "\n")
                lastStatus = 1
            }
        }
    }

    private enum class PipelinePosition { SOLO, FIRST, MIDDLE, LAST }

    private fun runPipelineNode(commands: List<ShellNode>, negated: Boolean, state: EvalState) {
        var pipe = ""
        val statuses = ArrayList<Int>()
        for ((index, command) in commands.withIndex()) {
            val isLast = index == commands.size - 1
            val position = when {
                commands.size == 1 -> PipelinePosition.SOLO
                isLast -> PipelinePosition.LAST
                index == 0 -> PipelinePosition.FIRST
                else -> PipelinePosition.MIDDLE
            }
            if (command is ShellNode.Simple) {
                val out = runSimple(command.assignments, command.words, command.redirects, pipe, position, state)
                if (isLast) { state.sink.commandOut(out); pipe = "" } else pipe = out
            } else {
                // A compound in a pipeline: the pipe is its stdin, its stdout is captured.
                val sink = Sink.capture(state.sink)
                val child = state.child(sink = sink, stdin = StdinBuffer(pipe), interactive = false)
                evaluate(command, child)
                if (isLast) state.sink.commandOut(sink.captured) else pipe = sink.captured
            }
            statuses.add(lastStatus)
        }
        var status = statuses.lastOrNull() ?: 0
        if (optionPipefail) statuses.lastOrNull { it != 0 }?.let { status = it }
        if (negated) status = if (status == 0) 1 else 0
        lastStatus = status
    }

    /**
     * One command: expand, apply redirects and scoped assignments, run. Returns raw stdout (the
     * caller decides whether it feeds a pipe, a capture, or the scrollback).
     */
    private fun runSimple(
        assignments: List<Pair<String, ShellWord>>,
        words: List<ShellWord>,
        redirects: List<ShellRedirect>,
        pipedIn: String,
        pipelinePosition: PipelinePosition,
        state: EvalState,
    ): String {
        if (state.depth >= 48) throw ShellParseError("recursion too deep")

        val expandedAssignments = assignments.map { it.first to expandNoSplit(it.second, state) }

        val argv = ArrayList<String>()
        for (word in words) argv.addAll(expandWord(word, state))

        if (argv.isEmpty()) {
            // Assignments alone are permanent; a command's are scoped to it (below).
            for ((name, value) in expandedAssignments) env[name] = value
            lastStatus = 0
            return ""
        }

        if (optionTrace) state.sink.commandErr("+ ${argv.joinToString(" ")}\n")

        var stdin = pipedIn
        var stdoutFile: Pair<String, Boolean>? = null
        for (redirect in redirects) {
            val target = expandNoSplit(redirect.target, state)
            when (redirect.kind) {
                ShellRedirect.Kind.STDIN_READ -> {
                    val text = resolve(target, state.context)?.file?.takeIf { it.isFile }?.readText()
                    if (text == null) {
                        state.sink.commandErr("msh: can't read $target\n")
                        lastStatus = 1
                        return ""
                    }
                    stdin = text
                }
                ShellRedirect.Kind.STDOUT_WRITE -> stdoutFile = target to false
                ShellRedirect.Kind.STDOUT_APPEND -> stdoutFile = target to true
            }
        }

        val saved = ArrayList<Pair<String, String?>>()
        for ((name, value) in expandedAssignments) {
            saved.add(name to env[name])
            env[name] = value
        }
        try {
            val io = runCommand(argv, stdin, stdoutFile != null, pipelinePosition, state)
            if (io.err.isNotEmpty()) state.sink.commandErr(io.err)
            lastStatus = io.status
            if (stdoutFile != null) {
                write(io.out, stdoutFile.first, stdoutFile.second, state.context)?.let {
                    state.sink.commandErr(it + "\n")
                    lastStatus = 1
                }
                return ""
            }
            return io.out
        } finally {
            for ((name, value) in saved.asReversed()) {
                if (value == null) env.remove(name) else env[name] = value
            }
        }
    }

    /** Language builtins → functions → scripts → the builtin table. */
    private fun runCommand(
        argv: List<String>,
        stdin: String,
        redirectedOut: Boolean,
        pipelinePosition: PipelinePosition,
        state: EvalState,
    ): IO {
        val name = argv[0]
        val args = argv.drop(1)
        when (name) {
            "break" -> throw Control.BreakLoop(maxOf(1, args.firstOrNull()?.toIntOrNull() ?: 1))
            "continue" -> throw Control.ContinueLoop(maxOf(1, args.firstOrNull()?.toIntOrNull() ?: 1))
            "return" -> throw Control.ReturnStatus(args.firstOrNull()?.toIntOrNull() ?: lastStatus)
            "exit" -> throw Control.ExitShell(args.firstOrNull()?.toIntOrNull() ?: lastStatus)
            "shift" -> {
                val count = args.firstOrNull()?.toIntOrNull() ?: 1
                if (positionals.isEmpty()) return IO()
                val frame = positionals[positionals.lastIndex]
                if (count > frame.size) return IO(err = "msh: shift: not enough arguments\n", status = 1)
                repeat(count) { frame.removeAt(0) }
                return IO()
            }
            "local" -> {
                for (arg in args) {
                    val eq = arg.indexOf('=')
                    val varName = if (eq < 0) arg else arg.substring(0, eq)
                    if (localScopes.isNotEmpty()) {
                        val scope = localScopes[localScopes.lastIndex]
                        if (!scope.containsKey(varName)) scope[varName] = env[varName]
                    }
                    env[varName] = if (eq < 0) "" else arg.substring(eq + 1)
                }
                return IO()
            }
            "set" -> return setCmd(args)
            "read" -> return readCmd(args, stdin, state)
            "eval", "source", ".", "sh", "bash" -> return runScriptCommand(name, args, stdin, state)
        }

        functions[name]?.let { return callFunction(it, args, stdin, state) }

        val clean = !redirectedOut && state.sink.captureBuffer == null
        val interactive = clean && state.interactiveAllowed &&
            (pipelinePosition == PipelinePosition.SOLO || pipelinePosition == PipelinePosition.LAST)

        // ./script.sh, path/to/script.sh: a file in the workspace runs as a script.
        if (name.contains("/") || name.endsWith(".sh")) {
            val source = resolve(name, state.context)?.file?.takeIf { it.isFile }?.readText()
            if (source != null) return runScript(source, name, args, stdin, state)
        }

        return dispatch(
            argv, stdin, state.context,
            streaming = clean && pipelinePosition == PipelinePosition.SOLO,
            interactive = interactive,
        )
    }

    private fun callFunction(body: ShellNode, args: List<String>, stdin: String, state: EvalState): IO {
        positionals.add(args.toMutableList())
        localScopes.add(HashMap())
        val sink = Sink.capture(state.sink)
        try {
            val child = state.child(sink = sink, stdin = StdinBuffer(stdin), interactive = false)
            try {
                evaluate(body, child)
            } catch (control: Control) {
                if (control is Control.ReturnStatus) {
                    lastStatus = control.status
                } else {
                    // exit (or an outer break) unwinds through the call — what the function already
                    // wrote must still reach the terminal, like a real process's flushed stdout.
                    state.sink.commandOut(sink.captured)
                    throw control
                }
            }
            return IO(out = sink.captured, status = lastStatus)
        } finally {
            for ((name, oldValue) in localScopes.removeAt(localScopes.lastIndex)) {
                if (oldValue == null) env.remove(name) else env[name] = oldValue
            }
            positionals.removeAt(positionals.lastIndex)
        }
    }

    /**
     * `eval` and `source`/`.` run in the current scope; `sh`/`bash` get their own positional frame
     * and contain `exit`. `curl url | sh` runs the piped text.
     */
    private fun runScriptCommand(name: String, args: List<String>, stdin: String, state: EvalState): IO {
        when (name) {
            "eval" -> return runScript(args.joinToString(" "), null, emptyList(), stdin, state)
            "source", "." -> {
                val file = args.firstOrNull() ?: return IO(err = "$name: usage: $name <file>\n", status = 2)
                val text = resolve(file, state.context)?.file?.takeIf { it.isFile }?.readText()
                    ?: return IO(err = "$name: can't read $file\n", status = 1)
                val extra = args.drop(1)
                return runScript(text, if (extra.isEmpty()) null else file, extra, stdin, state)
            }
            else -> {   // sh, bash
                val flags = args.takeWhile { it.startsWith("-") }
                val rest = args.drop(flags.size)
                if (flags.contains("-c")) {
                    val source = rest.firstOrNull() ?: return IO(err = "$name: -c needs a command\n", status = 2)
                    return runScript(source, name, rest.drop(1), stdin, state)
                }
                rest.firstOrNull()?.let { file ->
                    val text = resolve(file, state.context)?.file?.takeIf { it.isFile }?.readText()
                        ?: return IO(err = "$name: can't read $file\n", status = 1)
                    return runScript(text, file, rest.drop(1), stdin, state)
                }
                if (stdin.isNotEmpty()) return runScript(stdin, name, emptyList(), "", state)
                return IO(err = "$name: usage: $name <script> | -c <command>\n", status = 2)
            }
        }
    }

    /**
     * The script runner. A non-null [name] pushes a positional frame ($0/$1…) and contains `exit`;
     * null (eval, plain source) runs in the caller's frame.
     */
    private fun runScript(source: String, name: String?, args: List<String>, stdin: String, state: EvalState): IO {
        var body = source
        if (body.startsWith("#!")) {
            val firstLine = body.takeWhile { it != '\n' }
            val interpreter = firstLine.drop(2).trim()
            val isShell = interpreter.endsWith("sh") || interpreter.contains("sh ") || interpreter.endsWith("bash")
            if (!isShell) return IO(err = "msh: no interpreter for $interpreter\n", status = 126)
            body = body.drop(firstLine.length)
        }
        val program: ShellNode
        try {
            program = ShellParser.parse(body)
        } catch (e: ShellParseError) {
            return IO(err = "msh: ${e.message}\n", status = 2)
        }
        if (name != null) {
            positionals.add(args.toMutableList())
            scriptNames.add(name)
        }
        try {
            val sink = Sink.capture(state.sink)
            val child = state.child(
                sink = sink,
                stdin = if (stdin.isEmpty()) state.stdin else StdinBuffer(stdin),
                interactive = false,
            )
            try {
                evaluate(program, child)
            } catch (control: Control) {
                when {
                    control is Control.ExitShell && name != null -> lastStatus = control.status
                    control is Control.ReturnStatus -> lastStatus = control.status
                    else -> {
                        state.sink.commandOut(sink.captured)
                        throw control
                    }
                }
            }
            return IO(out = sink.captured, status = lastStatus)
        } finally {
            if (name != null) {
                positionals.removeAt(positionals.lastIndex)
                scriptNames.removeAt(scriptNames.lastIndex)
            }
        }
    }

    private fun setCmd(args: List<String>): IO {
        var index = 0
        while (index < args.size) {
            val arg = args[index]
            if (arg == "--") {
                setPositionals(args.drop(index + 1))
                return IO()
            }
            if (arg == "-o" || arg == "+o") {
                if (index + 1 < args.size && args[index + 1] == "pipefail") optionPipefail = arg == "-o"
                index += 2
                continue
            }
            if (!arg.startsWith("-") && !arg.startsWith("+")) {
                setPositionals(args.drop(index))
                return IO()
            }
            val enable = arg.startsWith("-")
            for (flag in arg.drop(1)) when (flag) {
                'e' -> optionExitOnError = enable
                'x' -> optionTrace = enable
                else -> {}   // -u, -f and friends: accepted, not enforced
            }
            index++
        }
        return IO()
    }

    private fun setPositionals(params: List<String>) {
        if (positionals.isEmpty()) positionals.add(params.toMutableList())
        else positionals[positionals.lastIndex] = params.toMutableList()
    }

    private fun readCmd(args: List<String>, stdin: String, state: EvalState): IO {
        val names = args.filter { !it.startsWith("-") }
        val line: String? = when {
            stdin.isNotEmpty() -> stdin.substringBefore('\n')
            else -> state.stdin?.readLine()
        }
        if (line == null) {
            for (name in names) env[name] = ""
            return IO(status = 1)
        }
        if (names.isEmpty()) return IO()
        val fields = line.split(" ").filter { it.isNotEmpty() }
        for ((index, name) in names.withIndex()) {
            env[name] = if (index == names.size - 1) {
                if (index < fields.size) fields.subList(index, fields.size).joinToString(" ") else ""
            } else {
                if (index < fields.size) fields[index] else ""
            }
        }
        return IO()
    }

    // MARK: - test / [

    private fun testCmd(rawArgs: List<String>, bracket: Boolean, context: Context): IO {
        var args = rawArgs
        if (bracket) {
            if (args.lastOrNull() != "]" && args.lastOrNull() != "]]") return IO(err = "[: missing ]\n", status = 2)
            args = args.dropLast(1)
        }
        return IO(status = if (evaluateTest(args, context)) 0 else 1)
    }

    private fun evaluateTest(args: List<String>, context: Context): Boolean {
        // -a / -o bind loosest, left to right.
        args.lastIndexOf("-o").let { index ->
            if (index > 0 && index < args.size - 1) {
                return evaluateTest(args.subList(0, index), context) ||
                    evaluateTest(args.subList(index + 1, args.size), context)
            }
        }
        args.lastIndexOf("-a").let { index ->
            if (index > 0 && index < args.size - 1) {
                return evaluateTest(args.subList(0, index), context) &&
                    evaluateTest(args.subList(index + 1, args.size), context)
            }
        }
        if (args.firstOrNull() == "!") return !evaluateTest(args.drop(1), context)
        return when (args.size) {
            0 -> false
            1 -> args[0].isNotEmpty()
            2 -> {
                val value = args[1]
                when (args[0]) {
                    "-z" -> value.isEmpty()
                    "-n" -> value.isNotEmpty()
                    "-e", "-f", "-d", "-s", "-r", "-w", "-x" -> {
                        val file = resolve(value, context)?.file ?: return false
                        val exists = file.exists()
                        when (args[0]) {
                            "-e", "-r", "-w" -> exists
                            "-f" -> exists && !file.isDirectory
                            "-d" -> exists && file.isDirectory
                            "-x" -> exists && file.canExecute()
                            "-s" -> exists && file.length() > 0
                            else -> false
                        }
                    }
                    else -> false
                }
            }
            3 -> {
                val (lhs, op, rhs) = Triple(args[0], args[1], args[2])
                fun num(text: String) = text.toLongOrNull() ?: 0L
                when (op) {
                    "=", "==" -> lhs == rhs
                    "!=" -> lhs != rhs
                    "-eq" -> num(lhs) == num(rhs)
                    "-ne" -> num(lhs) != num(rhs)
                    "-lt" -> num(lhs) < num(rhs)
                    "-le" -> num(lhs) <= num(rhs)
                    "-gt" -> num(lhs) > num(rhs)
                    "-ge" -> num(lhs) >= num(rhs)
                    "<" -> lhs < rhs
                    ">" -> lhs > rhs
                    else -> false
                }
            }
            else -> false
        }
    }

    // MARK: - Expansion

    /**
     * [Text.splittable] field-splits on whitespace (unquoted expansion results); [Text.globbable]
     * means its metacharacters may glob (anything unquoted). [SeparateWords] is `"$@"`: each
     * parameter is its own word.
     */
    private sealed class Fragment {
        class Text(val text: String, val splittable: Boolean, val globbable: Boolean) : Fragment()
        class SeparateWords(val params: List<String>) : Fragment()
    }

    private val currentParams: List<String> get() = positionals.lastOrNull() ?: emptyList()

    /**
     * `$$` is the process id. `ProcessHandle` is JDK-only and absent from Android; `/proc/self`
     * resolves to the pid on Linux and Android but not on a Mac. Between them every platform this
     * shell runs on is covered, and the fallback keeps `$$` a number rather than a crash.
     */
    private val processId: String by lazy {
        runCatching { ProcessHandle.current().pid().toString() }
            .recoverCatching { File("/proc/self").canonicalFile.name }
            .getOrDefault("1")
    }

    private fun lookupParameter(name: String): String? = when (name) {
        "?" -> lastStatus.toString()
        "#" -> currentParams.size.toString()
        "$" -> processId
        "*", "@" -> currentParams.joinToString(" ")
        else -> {
            val index = name.toIntOrNull()
            if (name.isNotEmpty() && name.all { it.isDigit() } && index != null) {
                if (index == 0) scriptNames.lastOrNull() ?: "msh"
                else if (index <= currentParams.size) currentParams[index - 1] else ""
            } else {
                env[name]
            }
        }
    }

    /**
     * Word → argv: expansion, field splitting, globbing, tilde. One word can become many
     * (splitting, `"$@"`, globs) or none (an unquoted empty expansion).
     */
    private fun expandWord(word: ShellWord, state: EvalState): List<String> {
        val fragments = expandFragments(word, state)
        // A word containing any quoted part survives even when empty ("" is one empty arg) —
        // except a lone "$@", whose emptiness means zero words.
        val sawQuoted = word.any { part ->
            when (val quote = part.quote) {
                is ShellQuote.Single, is ShellQuote.Double -> part.text != "\$@"
                is ShellQuote.CommandSub -> quote.quoted
                is ShellQuote.Arithmetic -> quote.quoted
                is ShellQuote.None -> false
            }
        }

        val words = ArrayList<Pair<String, Boolean>>()
        var current = StringBuilder()
        var currentGlob = false
        fun flush() {
            if (current.isNotEmpty() || currentGlob) {
                words.add(current.toString() to currentGlob)
                current = StringBuilder()
                currentGlob = false
            }
        }
        for (fragment in fragments) {
            when (fragment) {
                is Fragment.SeparateWords -> for ((index, param) in fragment.params.withIndex()) {
                    if (index > 0) {
                        words.add(current.toString() to currentGlob)
                        current = StringBuilder()
                        currentGlob = false
                    }
                    current.append(param)
                }
                is Fragment.Text -> if (!fragment.splittable) {
                    if (fragment.globbable && fragment.text.any { it in "*?[" }) currentGlob = true
                    current.append(fragment.text)
                } else {
                    for (ch in fragment.text) {
                        if (ch == ' ' || ch == '\t' || ch == '\n') {
                            flush()
                        } else {
                            if (fragment.globbable && ch in "*?[") currentGlob = true
                            current.append(ch)
                        }
                    }
                }
            }
        }
        if (current.isNotEmpty() || currentGlob || (words.isEmpty() && sawQuoted)) {
            words.add(current.toString() to currentGlob)
        }

        val results = ArrayList<String>()
        for ((text, hasGlob) in words) {
            if (hasGlob) {
                val matches = glob(text, state.context)
                if (matches.isNotEmpty()) { results.addAll(matches); continue }
            }
            results.add(text)
        }
        return results
    }

    /**
     * Word → one string: expansion without field splitting or globbing (assignments, case subjects
     * and patterns, redirect targets).
     */
    private fun expandNoSplit(word: ShellWord, state: EvalState): String {
        val result = StringBuilder()
        for (fragment in expandFragments(word, state)) {
            when (fragment) {
                is Fragment.Text -> result.append(fragment.text)
                is Fragment.SeparateWords -> result.append(fragment.params.joinToString(" "))
            }
        }
        return result.toString()
    }

    private fun expandFragments(word: ShellWord, state: EvalState): List<Fragment> {
        val fragments = ArrayList<Fragment>()
        for ((index, part) in word.withIndex()) {
            when (val quote = part.quote) {
                is ShellQuote.Single -> fragments.add(Fragment.Text(part.text, splittable = false, globbable = false))
                is ShellQuote.None -> {
                    if (part.text == "\$@") { fragments.add(Fragment.SeparateWords(currentParams)); continue }
                    var text = part.text
                    if (index == 0 && text.startsWith("~")) text = "/" + text.drop(1)   // ~ is the workspace root
                    fragments.addAll(parseDollars(text, quoted = false, state = state))
                }
                is ShellQuote.Double -> {
                    if (part.text == "\$@") { fragments.add(Fragment.SeparateWords(currentParams)); continue }
                    fragments.addAll(parseDollars(part.text, quoted = true, state = state))
                }
                is ShellQuote.CommandSub -> {
                    val result = commandSubstitution(part.text, state).trimEnd('\n')
                    fragments.add(Fragment.Text(result, splittable = !quote.quoted, globbable = !quote.quoted))
                }
                is ShellQuote.Arithmetic -> {
                    val value = ShellArithmetic.evaluate(part.text) { lookupParameter(it) }
                    fragments.add(Fragment.Text(value.toString(), splittable = false, globbable = false))
                }
            }
        }
        return fragments
    }

    /** Scans `$NAME`, `${…}`, `$1`, `$?`, `$#`, `$$`, `$*` out of literal text. */
    private fun parseDollars(text: String, quoted: Boolean, state: EvalState): List<Fragment> {
        val fragments = ArrayList<Fragment>()
        val literal = StringBuilder()
        var i = 0

        fun flushLiteral() {
            if (literal.isNotEmpty()) {
                fragments.add(Fragment.Text(literal.toString(), splittable = false, globbable = !quoted))
                literal.setLength(0)
            }
        }
        fun emit(value: String) {
            flushLiteral()
            fragments.add(Fragment.Text(value, splittable = !quoted, globbable = !quoted))
        }

        while (i < text.length) {
            if (text[i] != '$' || i + 1 >= text.length) {
                literal.append(text[i]); i++; continue
            }
            val next = text[i + 1]
            when {
                next == '{' -> {
                    var depth = 1
                    var j = i + 2
                    val inner = StringBuilder()
                    while (j < text.length) {
                        if (text[j] == '{') depth++
                        if (text[j] == '}') { depth--; if (depth == 0) break }
                        inner.append(text[j])
                        j++
                    }
                    if (depth != 0) { literal.append(text[i]); i++; continue }
                    emit(expandBraced(inner.toString(), state))
                    i = j + 1
                }
                next == '@' || next == '*' -> { emit(currentParams.joinToString(" ")); i += 2 }
                next == '?' || next == '#' || next == '$' -> { emit(lookupParameter(next.toString()) ?: ""); i += 2 }
                next.isDigit() -> { emit(lookupParameter(next.toString()) ?: ""); i += 2 }
                next.isLetter() || next == '_' -> {
                    var j = i + 1
                    val name = StringBuilder()
                    while (j < text.length && (text[j].isLetter() || text[j].isDigit() || text[j] == '_')) {
                        name.append(text[j]); j++
                    }
                    emit(lookupParameter(name.toString()) ?: "")
                    i = j
                }
                else -> { literal.append(text[i]); i++ }
            }
        }
        flushLiteral()
        return fragments
    }

    /**
     * `${…}` bodies: `${#NAME}`, `${NAME}`, and the `:-  -  :=  =  :+  +  :?  ?  #  ##  %  %%`
     * operators. The operator's word is itself expanded (it may hold `$VAR` or `$(cmd)`).
     */
    private fun expandBraced(inner: String, state: EvalState): String {
        if (inner.startsWith("#") && inner.length > 1) {
            return (lookupParameter(inner.drop(1)) ?: "").length.toString()
        }
        var i = 0
        val name = StringBuilder()
        if (i < inner.length && (inner[i].isDigit() || inner[i] in "?#$*@")) {
            name.append(inner[i]); i++
            while (i < inner.length && inner[i].isDigit() && inner[0].isDigit()) { name.append(inner[i]); i++ }
        } else {
            while (i < inner.length && (inner[i].isLetter() || inner[i].isDigit() || inner[i] == '_')) {
                name.append(inner[i]); i++
            }
        }
        val key = name.toString()
        if (i >= inner.length) return lookupParameter(key) ?: ""

        val rest = inner.substring(i)
        val op = listOf(":-", ":=", ":+", ":?", "##", "%%", "-", "=", "+", "?", "#", "%")
            .firstOrNull { rest.startsWith(it) }
            ?: return lookupParameter(key) ?: ""
        val wordText = rest.substring(op.length)
        val value = lookupParameter(key)
        val isUnset = value == null
        val isEmpty = (value ?: "").isEmpty()

        fun word() = expandMiniWord(wordText, state)

        return when (op) {
            ":-" -> if (isEmpty) word() else value!!
            "-" -> if (isUnset) word() else value!!
            ":=" -> if (isEmpty) word().also { env[key] = it } else value!!
            "=" -> if (isUnset) word().also { env[key] = it } else value!!
            ":+" -> if (isEmpty) "" else word()
            "+" -> if (isUnset) "" else word()
            ":?", "?" -> {
                if (isEmpty) {
                    throw ShellParseError("$key: ${if (wordText.isEmpty()) "parameter not set" else word()}")
                }
                value!!
            }
            "#", "##" -> stripPattern(value ?: "", word(), prefix = true, longest = op == "##")
            "%", "%%" -> stripPattern(value ?: "", word(), prefix = false, longest = op == "%%")
            else -> value ?: ""
        }
    }

    private fun stripPattern(value: String, pattern: String, prefix: Boolean, longest: Boolean): String {
        // Candidate lengths run shortest-first; `longest` (##, %%) reverses.
        val lengths = (0..value.length).let { if (longest) it.reversed() else it.toList() }
        for (length in lengths) {
            val candidate = if (prefix) value.substring(0, length) else value.substring(value.length - length)
            if (ShellPattern.matches(pattern, candidate)) {
                return if (prefix) value.substring(length) else value.substring(0, value.length - length)
            }
        }
        return value
    }

    /** A `${X:-word}` word or `${X#pattern}` pattern: re-lex and expand without splitting. */
    private fun expandMiniWord(text: String, state: EvalState): String {
        if (text.isEmpty()) return ""
        val tokens = runCatching { ShellLexer.lex(text) }.getOrDefault(emptyList())
        return tokens.filterIsInstance<ShellToken.Word>()
            .joinToString(" ") { expandNoSplit(it.parts, state) }
    }

    private fun commandSubstitution(source: String, state: EvalState): String {
        if (state.depth >= 48) throw ShellParseError("recursion too deep")
        val program: ShellNode
        try {
            program = ShellParser.parse(source)
        } catch (e: ShellParseError) {
            state.sink.commandErr("msh: ${e.message}\n")
            lastStatus = 2
            return ""
        }
        val sink = Sink.capture(state.sink)
        val child = state.child(sink = sink, interactive = false)
        try {
            evaluate(program, child)
        } catch (control: Control) {
            if (control is Control.ExitShell) lastStatus = control.status else throw control
        }
        return sink.captured
    }

    private fun glob(pattern: String, context: Context): List<String> {
        val slash = pattern.lastIndexOf('/')
        val dirPattern = if (slash >= 0) pattern.substring(0, slash) else "."
        val namePattern = if (slash >= 0) pattern.substring(slash + 1) else pattern
        val dir = resolve(if (dirPattern.isEmpty()) "/" else dirPattern, context) ?: return emptyList()
        val entries = dir.file.listFiles() ?: return emptyList()
        val prefix = if (dirPattern == ".") "" else "$dirPattern/"
        return entries.map { it.name }
            .filter { !it.startsWith(".") && ShellPattern.matches(namePattern, it) }
            .sorted()
            .map { prefix + it }
    }

    // MARK: - Command I/O

    private class IO(var out: String = "", var err: String = "", var status: Int = 0)

    private fun write(text: String, file: String, append: Boolean, context: Context): String? {
        val target = resolve(file, context)
        if (target == null || target.rel.isEmpty()) return "msh: bad redirect target: $file"
        return try {
            val existing = if (append && target.file.exists()) target.file.readText() else ""
            target.file.parentFile?.mkdirs()
            target.file.writeText(existing + text)
            context.markModified(target.rel)
            null
        } catch (e: Exception) { "msh: write failed: ${e.message}" }
    }

    // MARK: - Built-ins

    /**
     * [interactive] is true when this command ends the pipeline with nowhere to redirect — the one
     * position where a builtin may take over the screen as a full-screen program.
     */
    private fun dispatch(
        argv: List<String>,
        stdin: String,
        context: Context,
        streaming: Boolean,
        interactive: Boolean,
    ): IO {
        val name = argv[0]
        val args = argv.drop(1)
        return when (name) {
            "help" -> IO(HELP)
            "clear" -> { context.clear(); IO() }
            "pwd" -> IO("/$cwd\n")
            "cd" -> cd(args, context)
            "ls" -> ls(args, context)
            "cat" -> cat(args, stdin, context)
            "echo" -> { val nl = args.firstOrNull() != "-n"; val body = (if (args.firstOrNull() == "-n") args.drop(1) else args).joinToString(" "); IO(body + if (nl) "\n" else "") }
            "printf" -> printf(args)
            "test" -> testCmd(args, bracket = false, context = context)
            "[", "[[" -> testCmd(args, bracket = true, context = context)
            "mkdir" -> mkdir(args, context)
            "touch" -> touch(args, context)
            "chmod" -> chmod(args, context)
            "rm" -> rm(args, context)
            "mv" -> moveOrCopy(args, false, context)
            "cp" -> moveOrCopy(args.filter { it != "-r" }, true, context)
            "head" -> headTail(args, stdin, true, context)
            "tail" -> headTail(args, stdin, false, context)
            "wc" -> wc(args, stdin, context)
            "sort" -> { val l = splitLines(input(args, stdin, context)).sorted().toMutableList(); if (args.contains("-r")) l.reverse(); IO(joinLines(l)) }
            "uniq" -> uniq(args, stdin, context)
            "tr" -> tr(args, stdin)
            "cut" -> cut(args, stdin, context)
            "seq" -> seq(args)
            "grep" -> grep(args, stdin, context)
            "find" -> find(args, context)
            "nl" -> IO(joinLines(splitLines(input(args, stdin, context)).mapIndexed { i, l -> "%6d  %s".format(i + 1, l) }))
            "rev" -> IO(joinLines(splitLines(input(args, stdin, context)).map { it.reversed() }))
            "tac" -> IO(joinLines(splitLines(input(args, stdin, context)).reversed()))
            "tee" -> tee(args, stdin, context)
            "xargs" -> dispatch((args.ifEmpty { listOf("echo") }) + stdin.split(Regex("\\s+")).filter { it.isNotEmpty() }, "", context, false, false)
            "base64" -> base64(args, stdin, context)
            "md5sum", "md5" -> checksum(args, stdin, context, "MD5")
            "sha256sum", "shasum" -> checksum(args, stdin, context, "SHA-256")
            // A real pager when the terminal can host one; cat into the scrollback when headless
            // or mid-pipeline. The Viewer stays the editor.
            "less", "more" -> {
                val content = cat(args, stdin, context)
                val launch = context.launchProgram
                if (!interactive || launch == null || content.err.isNotEmpty()) content
                else { launch(PagerProgram(content.out, argv.joinToString(" "))); IO() }
            }
            "sed" -> sed(args, stdin, context)
            "diff" -> diff(args, context)
            "date" -> IO(java.time.Instant.now().toString() + "\n")
            "uname" -> uname(args)
            "whoami" -> IO("mouse\n")
            "true" -> IO(status = 0)
            "false" -> IO(status = 1)
            "env" -> IO(joinLines(env.entries.sortedBy { it.key }.map { "${it.key}=${it.value}" }))
            "export" -> export(args)
            "unset" -> { args.forEach { env.remove(it) }; IO() }
            "history" -> IO(joinLines(history.mapIndexed { i, h -> "${i + 1}  $h" }))
            "which" -> if (BUILTINS.contains(args.firstOrNull())) IO("${args[0]}: msh built-in\n") else IO(err = "${args.firstOrNull()} not found", status = 1)
            "basename" -> IO((args.firstOrNull()?.substringAfterLast('/') ?: "") + "\n")
            "dirname" -> IO((args.firstOrNull()?.substringBeforeLast('/', ".")?.ifEmpty { "." } ?: ".") + "\n")
            "open" -> open(args, context)
            "sleep" -> sleepCmd(args, context)
            "ping" -> ping(args, context, streaming)
            "curl", "wget" -> curl(args, context)
            "pkg" -> pkgCmd(args, context)
            "node" -> nodeCmd(args, context, streaming)
            "npm" -> npmCmd(args, context, streaming)
            "npx" -> npxCmd(args, context, streaming)
            "git", "pnpm" -> IO(err = "$name: not built yet — the native ${if (name == "git") "git" else "package"} engine is on the roadmap", status = 127)
            // A name the CATALOG claims answers honestly, installed or not — that is why the
            // catalog knows an uninstalled runtime's commands. "command not found" for a `python`
            // that is sitting on disk is simply false.
            else -> runtimeCmd(name, args, context, streaming)
                ?: IO(err = "msh: command not found: $name (type help)", status = 127)
        }
    }

    private val BUILTINS = setOf(
        "help", "clear", "pwd", "cd", "ls", "cat", "echo", "printf", "mkdir", "touch", "rm", "mv", "cp",
        "head", "tail", "wc", "sort", "uniq", "tr", "cut", "seq", "grep", "find", "nl", "rev", "tac",
        "tee", "xargs", "base64", "md5sum", "sha256sum", "sed", "diff", "date", "whoami", "true", "false",
        "env", "export", "unset", "history", "which", "basename", "dirname", "open", "sleep", "ping", "curl", "wget",
        "less", "more", "pkg", "test", "[", "chmod", "uname",
        "if", "for", "while", "until", "case", "eval", "source", ".", "sh", "set", "read", "shift", "local",
        "break", "continue", "return", "exit",
    )

    private val HELP = """
        msh — built-ins:
          ls cd pwd cat echo printf mkdir touch chmod rm mv cp head tail wc sort uniq
          tr cut seq grep find nl rev tac tee xargs base64 md5sum sha256sum
          sed 's/re/sub/g'  diff <a> <b>  ping [-c N] <host>  curl [-o f] <url>
          sleep  date  uname  env  export NAME=v  unset  history (!!, !N)  which  open
          less <file>  (j/k space/b g/G q)
          pkg list | pkg install <runtime> | pkg remove <runtime>
        grammar: 'quotes' "with ${'$'}VARS"  |  > >> <  ;  &&  ||  ~  *  ?  ${'$'}?
          if c; then a; elif b; then a; else a; fi        while c; do a; done
          for x in a b; do a; done                        until c; do a; done
          case ${'$'}x in p) a ;; *) a ;; esac                name() { a; }
          test / [ ]   ${'$'}(cmd)  `cmd`  ${'$'}((n + 1))  ${'$'}{x:-y} ${'$'}{x##p} ${'$'}{#x}
          set -e -x -o pipefail   ${'$'}1 ${'$'}# ${'$'}@   shift   local   return   exit
          eval  source f  . f  sh f  ./f.sh   read v   break  continue
        a streaming command (ping without -c) stops on any keypress
    """.trimIndent()

    /**
     * `pkg` — install a language runtime. A port of `pkgCmd` in Shell.swift, subcommand for
     * subcommand, because the two shells are meant to be the same shell.
     *
     * Nothing here knows a language by name: the catalog is `swift/Runtimes.json`, shared with
     * iOS, and adding language N+1 is a JSON entry and nothing else.
     */
    private fun pkgCmd(args: List<String>, context: Context): IO {
        val support = context.runtimes
            ?: return IO(err = "pkg: no runtime store on this session", status = 1)
        val catalog = support.catalog
        return when (val action = args.firstOrNull() ?: "list") {
            "list", "ls" -> IO(
                catalog.joinToString("") { entry ->
                    val mark = if (support.store.installed(entry) != null) "installed" else "available"
                    "${entry.name} ${entry.version}  $mark  — ${entry.summary}\n"
                },
            )
            "install", "add" -> {
                val name = args.getOrNull(1)
                    ?: return IO(err = "pkg: install what? (`pkg list`)", status = 2)
                val entry = RuntimeCatalog.entry(catalog, name)
                    ?: return IO(
                        err = "pkg: no runtime called $name (have: ${catalog.joinToString(", ") { it.name }})",
                        status = 1,
                    )
                if (support.store.installed(entry) != null) {
                    return IO("${entry.name} ${entry.version} is already installed\n")
                }
                try {
                    // A multi-megabyte download with a silent terminal is indistinguishable from a
                    // hang, so each note lands in the scrollback as it happens. The caller already
                    // put this whole shell on an IO thread — see the class comment.
                    support.store.install(entry, note = { context.emit(Output(it, false)) })
                } catch (e: Exception) {
                    return IO(err = "pkg: ${e.message}", status = 1)
                }
                IO()
            }
            "remove", "rm", "uninstall" -> {
                val name = args.getOrNull(1)
                    ?: return IO(err = "pkg: remove what? (`pkg list`)", status = 2)
                val entry = RuntimeCatalog.entry(catalog, name)
                if (entry == null || !support.store.remove(entry)) {
                    IO(err = "pkg: $name is not installed", status = 1)
                } else {
                    IO("removed $name\n")
                }
            }
            else -> IO(err = "pkg: $action? (list, install, remove)", status = 2)
        }
    }

    /**
     * A language runtime typed at the prompt. Returns null when no catalog entry claims the name,
     * which is the caller's "command not found".
     *
     * Two honest answers, no third: not installed, or installed-but-not-runnable-yet. Running the
     * module is the phase-G engine's `node:wasi` — the shared bootstrap reaches for the standard
     * `WebAssembly` API, so a WebView supplies the wasm natively, but the launch path from msh into
     * the engine is milestone 3d and does not exist here yet. Saying so is better than "command not
     * found", which would be a lie about a 30 MB interpreter sitting on disk.
     */
    /**
     * `node script.js`, `node -e code`, and `node` with neither (which is a REPL on a real node
     * and is refused here by name — a REPL needs the terminal, not the engine).
     *
     * Output streams when the command runs solo and is collected inside a pipeline, the same rule
     * `ping` follows: `node app.js | grep ready` has to work as strings.
     */
    private fun nodeCmd(args: List<String>, context: Context, streaming: Boolean): IO {
        val run = context.runNode
            ?: return IO(err = "node: no engine attached", status = 127)
        val collected = StringBuilder()
        val errors = StringBuilder()
        val emit: (Output) -> Unit = { out ->
            if (streaming) context.emit(out)
            else if (out.isError) errors.append(out.text) else collected.append(out.text)
        }

        if (args.firstOrNull() == "-e" || args.firstOrNull() == "--eval") {
            val code = args.getOrNull(1)
                ?: return IO(err = "node: -e needs code", status = 9)
            val status = run.run(code, "/[eval].js", listOf("node") + args.drop(2), env, emptyList(), emit)
            return IO(collected.toString(), errors.toString(), status)
        }

        val script = args.firstOrNull()
            ?: return IO(err = "node: a REPL needs a terminal of its own; run a file or `node -e`", status = 9)
        val target = resolve(script, context)
            ?: return IO(err = "node: invalid path: $script", status = 1)
        if (!target.file.isFile) {
            return IO(err = "node: cannot find module '${display(target.rel)}'", status = 1)
        }
        val source = runCatching { target.file.readText() }.getOrNull()
            ?: return IO(err = "node: can't read ${display(target.rel)}", status = 1)
        val path = "/" + target.rel
        val argv = listOf("node", path) + args.drop(1)
        val status = run.run(source, path, argv, env, emptyList(), emit)
        return IO(collected.toString(), errors.toString(), status)
    }

    /**
     * `pkg@range` → the pair `install` wants. A scoped name keeps its own `@`: only the LAST one
     * separates a version, which is why this scans from the end.
     */
    private fun splitSpec(spec: String): Pair<String, String> {
        val at = spec.lastIndexOf('@')
        if (at <= 0) return spec to "latest"
        return spec.substring(0, at) to spec.substring(at + 1).ifEmpty { "latest" }
    }

    /** `npm install`, `npm run` and the aliases people actually type. */
    private fun npmCmd(args: List<String>, context: Context, streaming: Boolean): IO {
        return when (val sub = args.firstOrNull() ?: "install") {
            "install", "i", "add", "ci", "update" -> {
                val specs = args.drop(1).filter { !it.startsWith("-") }
                val requirements = LinkedHashMap<String, String>()
                for (spec in specs) {
                    val (name, requirement) = splitSpec(spec)
                    requirements[name] = requirement
                }
                if (requirements.isEmpty()) {
                    // A bare `npm install` means "what package.json asks for".
                    val declared = readDependencies(context) ?: return IO(
                        err = "npm: no package.json here, and nothing named to install", status = 1,
                    )
                    requirements.putAll(declared)
                }
                if (requirements.isEmpty()) return IO("up to date\n")
                val report = try {
                    PackageManager.install(requirements, context.root) { line ->
                        if (streaming) context.emit(Output(line + "\n", false))
                    }
                } catch (failure: Exception) {
                    return IO(err = "npm: ${failure.message}\n", status = 1)
                }
                context.markModified("package.json")
                IO("added ${report.placements.size} packages\n")
            }
            "run", "run-script" -> {
                val script = args.getOrNull(1)
                    ?: return IO(err = "npm run: which script?", status = 2)
                val command = readScripts(context)?.get(script)
                    ?: return IO(err = "npm run: no script named $script", status = 1)
                // A script is a SHELL line, not a program: `vite build && node fix.js` has to
                // work, and this shell is the one that runs it.
                execute(command, context).first.let { outputs ->
                    IO(
                        outputs.filter { !it.isError }.joinToString("") { it.text },
                        outputs.filter { it.isError }.joinToString("") { it.text },
                        lastStatus,
                    )
                }
            }
            else -> IO(err = "npm: $sub is not implemented — install, run", status = 1)
        }
    }

    /**
     * `npx <package> [args]` — install it if the tree does not already carry its bin, then run
     * that bin through the engine. Same shape as `Shell.swift`'s, including the fallback to a
     * package's single bin when its name does not match the package's.
     */
    private fun npxCmd(args: List<String>, context: Context, streaming: Boolean): IO {
        val spec = args.firstOrNull { !it.startsWith("-") }
            ?: return IO(err = "npx: usage: npx <package>", status = 2)
        val extra = args.dropWhile { it != spec }.drop(1)
        val (name, requirement) = splitSpec(spec)
        val short = name.substringAfterLast('/')

        var manifest = PackageManager.readManifest(context.root)
        if (manifest?.bins?.get(short) == null) {
            try {
                PackageManager.install(mapOf(name to requirement), context.root) { line ->
                    if (streaming) context.emit(Output(line + "\n", false))
                }
            } catch (failure: Exception) {
                return IO(err = "npx: ${failure.message}\n", status = 1)
            }
            context.markModified("package.json")
            manifest = PackageManager.readManifest(context.root)
        }
        val binPath = manifest?.bins?.get(short)
            ?: manifest?.bins?.takeIf { it.size == 1 }?.values?.first()
            ?: return IO(err = "npx: $name installs no executables", status = 1)
        return runInstalledBin(binPath, short, extra, context, streaming)
    }

    /** Run a package's own bin file as a node program. */
    private fun runInstalledBin(
        binPath: String,
        title: String,
        args: List<String>,
        context: Context,
        streaming: Boolean,
    ): IO {
        val run = context.runNode ?: return IO(err = "$title: no engine attached", status = 127)
        val file = File(context.root, binPath)
        val source = runCatching { file.readText() }.getOrNull()
            ?: return IO(err = "msh: missing bin file: $binPath\n", status = 127)
        val collected = StringBuilder()
        val errors = StringBuilder()
        val emit: (Output) -> Unit = { out ->
            if (streaming) context.emit(out)
            else if (out.isError) errors.append(out.text) else collected.append(out.text)
        }
        val path = "/" + binPath
        val status = run.run(source, path, listOf("node", path) + args, env, emptyList(), emit)
        return IO(collected.toString(), errors.toString(), status)
    }

    /** `dependencies` + `devDependencies` from the workspace's own package.json. */
    private fun readDependencies(context: Context): Map<String, String>? {
        val text = runCatching { File(context.root, "package.json").readText() }.getOrNull() ?: return null
        val root = runCatching { Json.parse(text) as? Map<*, *> }.getOrNull() ?: return null
        val out = LinkedHashMap<String, String>()
        for (key in listOf("dependencies", "devDependencies")) {
            val section = root[key] as? Map<*, *> ?: continue
            for ((name, requirement) in section) out[name.toString()] = requirement.toString()
        }
        return out
    }

    /** `scripts` from the workspace's own package.json. */
    private fun readScripts(context: Context): Map<String, String>? {
        val text = runCatching { File(context.root, "package.json").readText() }.getOrNull() ?: return null
        val root = runCatching { Json.parse(text) as? Map<*, *> }.getOrNull() ?: return null
        val scripts = root["scripts"] as? Map<*, *> ?: return null
        return scripts.entries.associate { it.key.toString() to it.value.toString() }
    }

    private fun runtimeCmd(
        name: String,
        args: List<String>,
        context: Context,
        streaming: Boolean = false,
    ): IO? {
        val support = context.runtimes ?: return null
        val entry = RuntimeCatalog.forCommand(support.catalog, name) ?: return null
        val installed = support.store.installed(entry)
            ?: return IO(err = "$name: not installed — `pkg install ${entry.name}`", status = 127)
        val run = context.runNode
            ?: return IO(err = "$name: no engine attached", status = 127)

        // Where the runtime appears to a script. It really lives outside the workspace, under the
        // app's own storage, and a program must never learn that path — same rule as "/" itself.
        val mount = "/usr/lib/" + entry.name
        // A bare script name means a file in the CURRENT directory and the interpreter has no cwd
        // of its own: every WASI path is absolute. Anything naming a real file becomes its
        // absolute virtual path; flags and inline code are left alone.
        val argv = listOf(entry.name) + args.map { argument ->
            if (!entry.rewriteScriptPaths || argument.startsWith("-")) return@map argument
            val resolved = resolve(argument, context) ?: return@map argument
            if (resolved.file.isFile) "/" + resolved.rel else argument
        }
        val environment = entry.env.mapValues { it.value.replace("{root}", mount) }
        val bootstrap = wasiBootstrap(mount, entry.wasm, argv, environment)
        val collected = StringBuilder()
        val errors = StringBuilder()
        val emit: (Output) -> Unit = { out ->
            if (streaming) context.emit(out)
            else if (out.isError) errors.append(out.text) else collected.append(out.text)
        }
        val status = run.run(
            bootstrap, "/[${entry.name}].js", argv, env,
            listOf(mount to installed.directory), emit,
        )
        return IO(collected.toString(), errors.toString(), status)
    }

    /**
     * The JavaScript that runs a wasm interpreter. Same `node:wasi` and same `WebAssembly` as
     * `Shell.swift` generates — that is the point, both are the SHARED bootstrap's, and Android
     * needs no interpreter of its own because the WebView's V8 compiles the wasm natively.
     *
     * It diverges from iOS in exactly one place, for a reason that is this platform's alone:
     * **V8 refuses a SYNCHRONOUS `new WebAssembly.Module()` over 8 MB on the main thread**, and
     * the WebView's JavaScript has no other thread to run on. `python.wasm` is 14 MB, so the
     * synchronous form iOS uses fails outright:
     *
     *     RangeError: WebAssembly.Compile is disallowed on the main thread, if the buffer size
     *     is larger than 8MB. Use WebAssembly.compile, …
     *
     * So the compile is the asynchronous one. The interval is not decoration: a pending
     * `WebAssembly.compile` is a promise, and a promise is a microtask rather than an open
     * handle, so the loop would find nothing to wait for and end the program mid-compile — the
     * same rule that decides when `node script.js` is over. A ref'd timer IS a reason to stay
     * alive, and it is cleared the moment the module lands.
     */
    private fun wasiBootstrap(
        mount: String,
        wasm: String,
        argv: List<String>,
        environment: Map<String, String>,
    ): String = """
        const fs = require('fs');
        const { WASI } = require('node:wasi');
        const wasi = new WASI({
          version: 'preview1',
          args: ${jsJson(argv)},
          env: ${jsJson(environment)},
          preopens: { '/': '/' },
          returnOnExit: true,
        });
        const compiling = setInterval(function () {}, 1000);
        WebAssembly.instantiate(fs.readFileSync('$mount/$wasm'), wasi.getImportObject()).then(
          function (result) {
            clearInterval(compiling);
            const code = wasi.start(result.instance);
            if (code) process.exitCode = code;
          },
          function (error) {
            clearInterval(compiling);
            throw error;
          },
        );
    """.trimIndent()

    /**
     * A JSON literal, which is also a valid JavaScript expression — the same trick
     * `Shell.jsJSON` uses. U+2028/2029 are ordinary in JSON and statement-ending in JavaScript,
     * so they are escaped.
     */
    private fun jsJson(value: Any?): String = when (value) {
        null -> "null"
        is String -> buildString {
            append('"')
            for (ch in value) when {
                ch == '"' -> append("\\\"")
                ch == '\\' -> append("\\\\")
                ch == '\n' -> append("\\n")
                ch == '\r' -> append("\\r")
                ch == '\t' -> append("\\t")
                ch.code == 0x2028 -> append("\\u2028")
                ch.code == 0x2029 -> append("\\u2029")
                ch < ' ' -> append("\\u%04x".format(ch.code))
                else -> append(ch)
            }
            append('"')
        }
        is List<*> -> value.joinToString(",", "[", "]") { jsJson(it) }
        is Map<*, *> -> value.entries.joinToString(",", "{", "}") { jsJson(it.key.toString()) + ":" + jsJson(it.value) }
        else -> value.toString()
    }

    private fun cd(args: List<String>, context: Context): IO {
        val target = resolve(args.firstOrNull() ?: "/", context) ?: return IO(err = "cd: invalid path", status = 1)
        if (!target.file.isDirectory) return IO(err = "cd: not a directory: ${display(target.rel)}", status = 1)
        cwd = target.rel; env["PWD"] = "/$cwd"; return IO()
    }

    private fun ls(args: List<String>, context: Context): IO {
        val showHidden = args.contains("-a")
        val path = args.firstOrNull { !it.startsWith("-") } ?: "."
        val target = resolve(path, context) ?: return IO(err = "ls: invalid path", status = 1)
        if (!target.file.exists()) return IO(err = "ls: no such path: ${display(target.rel)}", status = 1)
        if (!target.file.isDirectory) return IO(display(target.rel) + "\n")
        val entries = target.file.listFiles() ?: return IO(err = "ls: can't read: ${display(target.rel)}", status = 1)
        val names = entries.filter { showHidden || !it.name.startsWith(".") }
            .sortedWith(compareByDescending<File> { it.isDirectory }.thenBy { it.name.lowercase() })
            .map { if (it.isDirectory) it.name + "/" else it.name }
        return IO(if (names.isEmpty()) "(empty)\n" else names.joinToString("  ") + "\n")
    }

    private fun cat(args: List<String>, stdin: String, context: Context): IO {
        val files = args.filter { !it.startsWith("-") }
        if (files.isEmpty()) return IO(stdin)
        val out = StringBuilder()
        for (file in files) {
            val target = resolve(file, context)?.file?.takeIf { it.exists() } ?: return IO(err = "cat: no such file: $file", status = 1)
            if (target.length() >= 400_000) return IO(err = "cat: file too large (${target.length() / 1024} KB)", status = 1)
            out.append(target.readText())
        }
        return IO(out.toString())
    }

    private fun printf(args: List<String>): IO {
        val format = args.firstOrNull()?.replace("\\n", "\n")?.replace("\\t", "\t")
            ?: return IO(err = "printf: usage: printf <format> [args…]", status = 1)
        val rest = args.drop(1).iterator()
        val out = StringBuilder()
        var i = 0
        while (i < format.length) {
            val ch = format[i]
            if (ch == '%' && i + 1 < format.length) {
                when (format[i + 1]) {
                    's' -> out.append(if (rest.hasNext()) rest.next() else "")
                    'd' -> out.append((if (rest.hasNext()) rest.next() else "").toIntOrNull() ?: 0)
                    '%' -> out.append('%')
                    else -> { out.append(ch); out.append(format[i + 1]) }
                }
                i += 2; continue
            }
            out.append(ch); i++
        }
        return IO(out.toString())
    }

    /** `-p` is the behavior anyway; filtering flags is what keeps `mkdir -p x` from making `-p`. */
    private fun mkdir(args: List<String>, context: Context): IO {
        val dirs = args.filter { !it.startsWith("-") }
        if (dirs.isEmpty()) return IO(err = "mkdir: usage: mkdir [-p] <dir…>", status = 1)
        for (dir in dirs) {
            val target = resolve(dir, context) ?: return IO(err = "mkdir: bad path: $dir", status = 1)
            if (!target.file.isDirectory && !target.file.mkdirs()) {
                return IO(err = "mkdir: can't create ${display(target.rel)}", status = 1)
            }
        }
        return IO()
    }

    private fun touch(args: List<String>, context: Context): IO {
        if (args.isEmpty()) return IO(err = "touch: usage: touch <file…>", status = 1)
        for (arg in args) {
            val target = resolve(arg, context) ?: return IO(err = "touch: bad path: $arg", status = 1)
            if (!target.file.exists()) {
                target.file.parentFile?.mkdirs()
                target.file.createNewFile()
                context.markModified(target.rel)
            }
        }
        return IO()
    }

    /**
     * Octal mode through `File`'s three permission setters rather than `java.nio.file` — NIO's
     * `PosixFilePermissions` is API 26 on Android, and this module targets everything `:app` does.
     * Each bit becomes "may owner" plus "owner only", which is exactly what the setters express.
     */
    private fun chmod(args: List<String>, context: Context): IO {
        val mode = args.firstOrNull()?.toIntOrNull(8)
        if (args.size < 2 || mode == null) return IO(err = "chmod: usage: chmod <octal-mode> <file…>", status = 1)
        for (file in args.drop(1)) {
            val target = resolve(file, context)?.file?.takeIf { it.exists() }
                ?: return IO(err = "chmod: no such file: $file", status = 1)
            for ((bit, set) in listOf<Pair<Int, (Boolean, Boolean) -> Boolean>>(
                4 to target::setReadable,
                2 to target::setWritable,
                1 to target::setExecutable,
            )) {
                val owner = (mode shr 6) and bit != 0
                val others = (((mode shr 3) or mode) and bit) != 0
                set(owner || others, !others)
            }
        }
        return IO()
    }

    /**
     * The real kernel name, so `case $(uname) in Darwin|Linux)` answers truthfully on both the
     * device and the harness machine. The JVM says "Mac OS X" where a shell says "Darwin".
     */
    private fun uname(args: List<String>): IO {
        val osName = System.getProperty("os.name") ?: "Linux"
        val sysname = if (osName.startsWith("Mac") || osName.startsWith("Darwin")) "Darwin" else osName
        val release = System.getProperty("os.version") ?: ""
        val machine = System.getProperty("os.arch") ?: ""
        return when {
            args.contains("-a") -> IO("$sysname localhost $release $machine\n")
            args.contains("-m") -> IO("$machine\n")
            args.contains("-r") -> IO("$release\n")
            else -> IO("$sysname\n")
        }
    }

    private fun rm(args: List<String>, context: Context): IO {
        val recursive = args.contains("-r")
        val targets = args.filter { !it.startsWith("-") }
        if (targets.isEmpty()) return IO(err = "rm: usage: rm [-r] <path…>", status = 1)
        for (arg in targets) {
            val target = resolve(arg, context) ?: return IO(err = "rm: invalid path: $arg", status = 1)
            if (target.rel.isEmpty()) return IO(err = "rm: refusing to remove the workspace root", status = 1)
            if (!target.file.exists()) return IO(err = "rm: no such path: ${display(target.rel)}", status = 1)
            if (target.file.isDirectory && !recursive) return IO(err = "rm: is a directory (use rm -r): ${display(target.rel)}", status = 1)
            if (!target.file.deleteRecursively()) return IO(err = "rm: failed: ${display(target.rel)}", status = 1)
        }
        return IO()
    }

    private fun moveOrCopy(args: List<String>, copy: Boolean, context: Context): IO {
        val name = if (copy) "cp" else "mv"
        if (args.size < 2) return IO(err = "$name: usage: $name <source> <destination>", status = 1)
        val source = resolve(args[0], context) ?: return IO(err = "$name: bad source", status = 1)
        val destination = resolve(args[1], context) ?: return IO(err = "$name: bad destination", status = 1)
        return try {
            if (copy) source.file.copyRecursively(destination.file, overwrite = true)
            else { source.file.copyRecursively(destination.file, overwrite = true); source.file.deleteRecursively() }
            if (destination.file.isFile) context.markModified(destination.rel)
            IO()
        } catch (e: Exception) { IO(err = "$name: ${e.message}", status = 1) }
    }

    private fun headTail(args: List<String>, stdin: String, fromStart: Boolean, context: Context): IO {
        var count = 10; var fileArg: String? = null
        val it = args.iterator()
        while (it.hasNext()) { val a = it.next(); if (a == "-n" && it.hasNext()) count = it.next().toIntOrNull() ?: 10 else if (!a.startsWith("-")) fileArg = a }
        val text = if (fileArg != null) resolve(fileArg, context)?.file?.takeIf { it.exists() }?.readText()
            ?: return IO(err = "${if (fromStart) "head" else "tail"}: can't read $fileArg", status = 1) else stdin
        val all = splitLines(text)
        return IO(joinLines(if (fromStart) all.take(count) else all.takeLast(count)))
    }

    private fun wc(args: List<String>, stdin: String, context: Context): IO {
        val text = input(args, stdin, context)
        val lines = splitLines(text).size
        val words = text.split(Regex("\\s+")).count { it.isNotEmpty() }
        val chars = text.length
        return when {
            args.contains("-l") -> IO("$lines\n")
            args.contains("-w") -> IO("$words\n")
            args.contains("-c") -> IO("$chars\n")
            else -> IO("$lines $words $chars\n")
        }
    }

    private fun uniq(args: List<String>, stdin: String, context: Context): IO {
        val counted = args.contains("-c")
        val out = ArrayList<String>(); var previous: String? = null; var count = 0
        fun flush() { previous?.let { out.add(if (counted) "%4d %s".format(count, it) else it) } }
        for (line in splitLines(input(args, stdin, context))) {
            if (line == previous) count++ else { flush(); previous = line; count = 1 }
        }
        flush(); return IO(joinLines(out))
    }

    private fun tr(args: List<String>, stdin: String): IO {
        if (args.size < 2) return IO(err = "tr: usage: tr <set1> <set2>", status = 1)
        val from = expandRanges(args[0]); val to = expandRanges(args[1])
        if (from.isEmpty() || to.isEmpty()) return IO(err = "tr: empty set", status = 1)
        val map = from.mapIndexed { i, c -> c to to[minOf(i, to.length - 1)] }.toMap()
        return IO(stdin.map { map[it] ?: it }.joinToString(""))
    }

    private fun expandRanges(set: String): String {
        val out = StringBuilder(); var i = 0
        while (i < set.length) {
            if (i + 2 < set.length && set[i + 1] == '-' && set[i] <= set[i + 2]) { for (c in set[i]..set[i + 2]) out.append(c); i += 3 }
            else { out.append(set[i]); i++ }
        }
        return out.toString()
    }

    private fun cut(args: List<String>, stdin: String, context: Context): IO {
        var delimiter = '\t'; var fields = listOf<Int>(); val files = ArrayList<String>()
        val it = args.iterator()
        while (it.hasNext()) { val a = it.next()
            when { a == "-d" && it.hasNext() -> delimiter = it.next().firstOrNull() ?: '\t'
                a == "-f" && it.hasNext() -> fields = it.next().split(",").mapNotNull { f -> f.toIntOrNull() }
                !a.startsWith("-") -> files.add(a) } }
        if (fields.isEmpty()) return IO(err = "cut: usage: cut -d X -f N[,M]", status = 1)
        val out = splitLines(input(files, stdin, context)).map { line ->
            val cols = line.split(delimiter)
            fields.mapNotNull { if (it in 1..cols.size) cols[it - 1] else null }.joinToString(delimiter.toString())
        }
        return IO(joinLines(out))
    }

    private fun seq(args: List<String>): IO {
        val nums = args.mapNotNull { it.toIntOrNull() }
        val (low, high) = when (nums.size) { 1 -> 1 to nums[0]; 2 -> nums[0] to nums[1]; else -> return IO(err = "seq: usage: seq [first] last", status = 1) }
        if (high < low || high - low >= 10_000) return IO(err = "seq: range too large", status = 1)
        return IO(joinLines((low..high).map { it.toString() }))
    }

    private fun grep(args: List<String>, stdin: String, context: Context): IO {
        val ci = args.contains("-i")
        val positional = args.filter { !it.startsWith("-") }
        val pattern = positional.firstOrNull() ?: return IO(err = "grep: usage: grep [-i] <pattern> [file…]", status = 1)
        val files = positional.drop(1)
        fun matches(line: String) = if (ci) line.contains(pattern, true) else line.contains(pattern)
        val out = ArrayList<String>()
        if (files.isEmpty()) out.addAll(splitLines(stdin).filter { matches(it) })
        else for (file in files) {
            val text = resolve(file, context)?.file?.takeIf { it.exists() }?.readText() ?: return IO(err = "grep: can't read $file", status = 1)
            splitLines(text).forEachIndexed { i, line -> if (matches(line)) { out.add(if (files.size > 1) "$file:${i + 1}: $line" else "${i + 1}: $line"); if (out.size >= 200) return@forEachIndexed } }
        }
        return IO(joinLines(out), status = if (out.isEmpty()) 1 else 0)
    }

    private fun find(args: List<String>, context: Context): IO {
        val arg = args.firstOrNull() ?: return IO(err = "find: usage: find <name>", status = 1)
        val start = resolve(".", context)?.file ?: return IO(status = 1)
        val isGlob = arg.any { it == '*' || it == '?' || it == '[' }
        val matches = ArrayList<String>()
        start.walkTopDown().onEnter { it.name != ".git" && it.name != "node_modules" }.forEach { f ->
            val hit = if (isGlob) ShellPattern.matches(arg, f.name) else f.name.contains(arg, true)
            if (hit && f != start) { matches.add(f.path.removePrefix(context.root.path + "/")); if (matches.size >= 200) return@forEach }
        }
        return IO(joinLines(matches), status = if (matches.isEmpty()) 1 else 0)
    }

    private fun tee(args: List<String>, stdin: String, context: Context): IO {
        val append = args.contains("-a")
        for (file in args.filter { !it.startsWith("-") }) write(stdin, file, append, context)?.let { return IO(err = it, status = 1) }
        return IO(stdin)
    }

    private fun base64(args: List<String>, stdin: String, context: Context): IO {
        val decode = args.contains("-d")
        val text = input(args.filter { it != "-d" }, stdin, context)
        return if (decode) {
            val bytes = runCatching { Base64.getDecoder().decode(text.trim()) }.getOrNull() ?: return IO(err = "base64: invalid input", status = 1)
            IO(String(bytes))
        } else IO(Base64.getEncoder().encodeToString(text.toByteArray()) + "\n")
    }

    private fun checksum(args: List<String>, stdin: String, context: Context, algorithm: String): IO {
        val files = args.filter { !it.startsWith("-") }
        fun digest(bytes: ByteArray) = MessageDigest.getInstance(algorithm).digest(bytes).joinToString("") { "%02x".format(it) }
        if (files.isEmpty()) return IO(digest(stdin.toByteArray()) + "  -\n")
        val out = ArrayList<String>()
        for (file in files) {
            val bytes = resolve(file, context)?.file?.takeIf { it.exists() }?.readBytes()
                ?: return IO(err = "${if (algorithm == "MD5") "md5sum" else "sha256sum"}: can't read $file", status = 1)
            out.add("${digest(bytes)}  $file")
        }
        return IO(joinLines(out))
    }

    private fun sed(args: List<String>, stdin: String, context: Context): IO {
        val script = args.firstOrNull()
        if (script == null || !script.startsWith("s") || script.length < 4) return IO(err = "sed: usage: sed 's/regex/replacement/[g]' [file]", status = 1)
        val delimiter = script[1]
        val pieces = script.drop(2).split(delimiter)
        if (pieces.size < 2) return IO(err = "sed: bad substitution: $script", status = 1)
        val regex = runCatching { Regex(pieces[0]) }.getOrNull() ?: return IO(err = "sed: bad regex: ${pieces[0]}", status = 1)
        var replacement = pieces[1]
        for (g in 1..9) replacement = replacement.replace("\\$g", "$$g")
        val global = pieces.size > 2 && pieces[2].contains("g")
        val text = input(args.drop(1), stdin, context)
        val out = splitLines(text).map { line -> if (global) regex.replace(line, replacement) else regex.replaceFirst(line, replacement) }
        return IO(joinLines(out))
    }

    private fun diff(args: List<String>, context: Context): IO {
        if (args.size != 2) return IO(err = "diff: usage: diff <fileA> <fileB>", status = 1)
        val a = resolve(args[0], context)?.file?.takeIf { it.exists() }?.readText() ?: return IO(err = "diff: can't read ${args[0]}", status = 1)
        val b = resolve(args[1], context)?.file?.takeIf { it.exists() }?.readText() ?: return IO(err = "diff: can't read ${args[1]}", status = 1)
        val la = splitLines(a); val lb = splitLines(b)
        if (la == lb) return IO(status = 0)
        if (la.size * lb.size > 4_000_000) return IO("files differ (${la.size} vs ${lb.size} lines — too large for a line diff)\n", status = 1)
        val table = Array(la.size + 1) { IntArray(lb.size + 1) }
        for (i in la.size - 1 downTo 0) for (j in lb.size - 1 downTo 0)
            table[i][j] = if (la[i] == lb[j]) table[i + 1][j + 1] + 1 else maxOf(table[i + 1][j], table[i][j + 1])
        val out = ArrayList<String>(); var i = 0; var j = 0
        while (i < la.size || j < lb.size) {
            when {
                i < la.size && j < lb.size && la[i] == lb[j] -> { i++; j++ }
                j == lb.size || (i < la.size && table[i + 1][j] >= table[i][j + 1]) -> { out.add("- ${la[i]}"); i++ }
                else -> { out.add("+ ${lb[j]}"); j++ }
            }
            if (out.size > 500) { out.add("… diff truncated at 500 lines"); break }
        }
        return IO(joinLines(out), status = 1)
    }

    private fun export(args: List<String>): IO {
        for (arg in args) {
            // Everything here is exported already (one process); a bare NAME is a no-op that
            // succeeds, NAME=value assigns. This used to reject a bare NAME, which made the
            // `export PATH` that ends every install script a hard error.
            val eq = arg.indexOf('=')
            if (eq >= 0) env[arg.substring(0, eq)] = arg.substring(eq + 1)
        }
        return IO()
    }

    private fun open(args: List<String>, context: Context): IO {
        val target = resolve(args.firstOrNull() ?: return IO(err = "open: usage: open <file>", status = 1), context) ?: return IO(err = "open: invalid path", status = 1)
        if (!target.file.isFile) return IO(err = "open: not a file: ${display(target.rel)}", status = 1)
        context.openFile(target.rel); return IO("opened ${display(target.rel)} in the viewer\n")
    }

    // MARK: - Streaming & network

    private fun sleepCmd(args: List<String>, context: Context): IO {
        val seconds = args.firstOrNull()?.toDoubleOrNull() ?: return IO(err = "sleep: usage: sleep <seconds>", status = 1)
        if (seconds < 0 || seconds > 3600) return IO(err = "sleep: out of range", status = 1)
        val end = System.currentTimeMillis() + (seconds * 1000).toLong()
        while (System.currentTimeMillis() < end && context.isActive()) Thread.sleep(50)
        return IO(status = if (context.isActive()) 0 else 130)
    }

    /**
     * Real reachability + RTT via `InetAddress.isReachable` (ICMP where the OS allows it, else a
     * TCP echo) — no raw sockets or NDK needed on Android. Solo it streams a line per second until
     * any keypress interrupts; in a pipeline it collects (default -c 4).
     */
    private fun ping(args: List<String>, context: Context, streaming: Boolean): IO {
        var count: Int? = null; var host: String? = null
        val it = args.iterator()
        while (it.hasNext()) { val a = it.next(); if (a == "-c" && it.hasNext()) count = it.next().toIntOrNull() else if (!a.startsWith("-")) host = a }
        if (host == null) return IO(err = "ping: usage: ping [-c N] <host>", status = 1)
        val limit = count ?: if (streaming) Int.MAX_VALUE else 4
        val address = runCatching { InetAddress.getByName(host) }.getOrNull()
            ?: return IO(err = "ping: cannot resolve $host", status = 1)

        val collected = ArrayList<String>()
        fun line(text: String) { if (streaming) context.emit(Output(text, false)) else collected.add(text) }
        line("PING $host (${address.hostAddress}): reachability probe")
        var sent = 0; var received = 0
        while (sent < limit && context.isActive()) {
            sent++
            val start = System.nanoTime()
            val ok = runCatching { address.isReachable(2000) }.getOrDefault(false)
            if (!context.isActive()) break
            if (ok) { received++; line("reply from ${address.hostAddress}: seq=$sent time=%.2f ms".format((System.nanoTime() - start) / 1_000_000.0)) }
            else line("request timeout for seq $sent")
            if (sent < limit) { val elapsed = (System.nanoTime() - start) / 1_000_000; if (elapsed < 1000) Thread.sleep(1000 - elapsed) }
        }
        val loss = if (sent == 0) 0 else ((sent - received) * 100.0 / sent).toInt()
        line("--- $host ping statistics ---")
        line("$sent probes sent, $received reachable, $loss% loss")
        return IO(if (streaming) "" else joinLines(collected), status = if (received > 0) 0 else 1)
    }

    private fun curl(args: List<String>, context: Context): IO {
        var outFile: String? = null; var urlString: String? = null
        val it = args.iterator()
        while (it.hasNext()) { val a = it.next(); if (a == "-o" && it.hasNext()) outFile = it.next() else if (!a.startsWith("-")) urlString = a }
        if (urlString == null) return IO(err = "curl: usage: curl [-o file] <url>", status = 1)
        if (!urlString.contains("://")) urlString = "https://$urlString"
        return try {
            val connection = (URL(urlString).openConnection() as HttpURLConnection).apply { instanceFollowRedirects = true }
            val code = connection.responseCode
            val stream = if (code in 200..299) connection.inputStream else connection.errorStream
            val data = stream?.readBytes() ?: ByteArray(0)
            val errStatus = if (code >= 400) 22 else 0
            if (outFile != null) {
                val target = resolve(outFile, context)
                if (target == null || target.rel.isEmpty()) return IO(err = "curl: bad output path: $outFile", status = 1)
                target.file.parentFile?.mkdirs(); target.file.writeBytes(data); context.markModified(target.rel)
                IO("saved ${display(target.rel)} (${data.size} bytes, HTTP $code)\n", status = errStatus)
            } else if (data.size >= 400_000) IO("curl: response too large to print (${data.size / 1024} KB) — use -o <file>\n", status = errStatus)
            else IO(String(data), status = errStatus)
        } catch (e: Exception) { IO(err = "curl: ${e.message}", status = 7) }
    }

    // MARK: - Helpers

    private fun input(args: List<String>, stdin: String, context: Context): String {
        val files = args.filter { !it.startsWith("-") }
        if (files.isEmpty()) return stdin
        return files.joinToString("") { resolve(it, context)?.file?.takeIf { f -> f.exists() }?.readText() ?: "" }
    }

    private fun splitLines(text: String): List<String> {
        if (text.isEmpty()) return emptyList()
        val lines = text.split("\n").toMutableList()
        if (lines.lastOrNull() == "") lines.removeAt(lines.size - 1)
        return lines
    }

    private fun joinLines(lines: List<String>): String = if (lines.isEmpty()) "" else lines.joinToString("\n") + "\n"

    private class Resolved(val rel: String, val file: File)

    private fun resolve(arg: String, context: Context): Resolved? {
        val components = if (arg.startsWith("/")) ArrayList() else ArrayList(cwd.split("/").filter { it.isNotEmpty() })
        for (piece in arg.split("/")) when (piece) {
            ".", "" -> {}
            ".." -> if (components.isNotEmpty()) components.removeAt(components.size - 1)
            else -> components.add(piece)
        }
        val rel = components.joinToString("/")
        return Resolved(rel, if (rel.isEmpty()) context.root else File(context.root, rel))
    }

    private fun display(rel: String) = if (rel.isEmpty()) "/" else rel
}
