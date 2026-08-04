package com.reagentsystems.mouse

import com.reagentsystems.mouse.packages.RuntimeCatalog
import com.reagentsystems.mouse.packages.RuntimeStore
import com.reagentsystems.mouse.terminal.PagerProgram
import com.reagentsystems.mouse.terminal.TerminalProgram
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.isActive
import kotlinx.coroutines.withContext
import java.io.File
import java.net.HttpURLConnection
import java.net.InetAddress
import java.net.URL
import java.security.MessageDigest
import java.util.Base64
import kotlin.coroutines.coroutineContext

/**
 * `msh` — the same from-scratch POSIX-flavored shell as the iOS app (`Shell.swift`), ported to
 * Kotlin so both platforms share one shell. Quoting, variables, globs, pipes, redirection,
 * sequencing, history, and ~50 built-ins. Strings flow between commands, so pipes/redirects are
 * exact; paths clamp to the workspace root. Android additionally offers the real `sh` engine —
 * this is the portable one that works everywhere.
 */
class MouseShell {
    class Context(
        val root: File,
        val markModified: (String) -> Unit = {},
        val openFile: (String) -> Unit = {},
        val clear: () -> Unit = {},
        val emit: (Output) -> Unit = {},
        /**
         * The language-runtime catalog and where installs live. Null in a harness with no app
         * around it, which is what makes `pkg` answer honestly instead of crashing.
         */
        val runtimes: RuntimeSupport? = null,
        /**
         * Hand a full-screen program the terminal. Null when nothing can host one (a harness,
         * or a command running mid-pipeline), which is why `less` falls back to `cat`.
         */
        val launchProgram: ((TerminalProgram) -> Unit)? = null,
    )

    data class Output(val text: String, val isError: Boolean)

    /** The catalog and the store, handed in together so `pkg` never reaches for a singleton. */
    class RuntimeSupport(val catalog: List<RuntimeCatalog.Entry>, val store: RuntimeStore)

    var cwd = ""; private set
    private var lastStatus = 0
    val history = ArrayList<String>()
    private val env = hashMapOf("HOME" to "/", "USER" to "mouse", "SHELL" to "msh", "PWD" to "/")

    val prompt: String get() = (if (cwd.isEmpty()) "~" else "~/$cwd") + " $"

    // MARK: - Entry

    suspend fun execute(rawLine: String, context: Context): Pair<List<Output>, String?> {
        var line = rawLine.trim()
        if (line.isEmpty()) return emptyList<Output>() to null

        var echo: String? = null
        expandHistory(line)?.let { (text, ok) ->
            if (!ok) return listOf(Output(text, true)) to null
            line = text; echo = line
        }
        history.add(line)
        if (history.size > 200) history.subList(0, history.size - 200).clear()

        val tokens = try { lex(line) } catch (e: ShellError) {
            lastStatus = 2; return listOf(Output("msh: ${e.message}", true)) to echo
        }

        val outputs = ArrayList<Output>()
        var i = 0
        var runNext = true
        while (i < tokens.size) {
            val pipeline = ArrayList<Token>()
            var connector = ";"
            while (i < tokens.size) {
                val t = tokens[i]
                if (t is Token.Op && (t.value == ";" || t.value == "&&" || t.value == "||")) {
                    connector = t.value; i++; break
                }
                pipeline.add(t); i++
            }
            if (runNext && pipeline.isNotEmpty()) outputs.addAll(runPipeline(pipeline, context))
            runNext = when (connector) {
                "&&" -> runNext && lastStatus == 0
                "||" -> runNext && lastStatus != 0
                else -> true
            }
        }
        return outputs to echo
    }

    private fun expandHistory(line: String): Pair<String, Boolean>? {
        if (!line.startsWith("!")) return null
        if (line == "!!") return history.lastOrNull()?.let { it to true } ?: ("msh: no history yet" to false)
        val n = line.drop(1).toIntOrNull()
        if (n != null && n in 1..history.size) return history[n - 1] to true
        return "msh: no such history entry: $line" to false
    }

    // MARK: - Lexer

    private class ShellError(message: String) : Exception(message)
    private enum class Quote { NONE, SINGLE, DOUBLE }
    private data class WordPart(val text: String, val quote: Quote)
    private sealed class Token {
        data class Word(val parts: List<WordPart>) : Token()
        data class Op(val value: String) : Token()
    }

    private fun lex(line: String): List<Token> {
        val tokens = ArrayList<Token>()
        var parts = ArrayList<WordPart>()
        val current = StringBuilder()
        var quote = Quote.NONE

        fun flushSegment() {
            if (current.isNotEmpty() || quote != Quote.NONE) { parts.add(WordPart(current.toString(), quote)); current.clear() }
        }
        fun flushWord() { flushSegment(); if (parts.isNotEmpty()) { tokens.add(Token.Word(parts)); parts = ArrayList() } }

        var i = 0
        while (i < line.length) {
            val ch = line[i]
            when (quote) {
                Quote.SINGLE -> if (ch == '\'') { parts.add(WordPart(current.toString(), Quote.SINGLE)); current.clear(); quote = Quote.NONE } else current.append(ch)
                Quote.DOUBLE -> when {
                    ch == '"' -> { parts.add(WordPart(current.toString(), Quote.DOUBLE)); current.clear(); quote = Quote.NONE }
                    ch == '\\' && i + 1 < line.length && line[i + 1] in "\"\\$" -> { i++; current.append(line[i]) }
                    else -> current.append(ch)
                }
                Quote.NONE -> when (ch) {
                    '\'' -> { flushSegment(); quote = Quote.SINGLE }
                    '"' -> { flushSegment(); quote = Quote.DOUBLE }
                    '\\' -> { if (i + 1 >= line.length) throw ShellError("trailing backslash"); i++; flushSegment(); parts.add(WordPart(line[i].toString(), Quote.SINGLE)) }
                    ' ', '\t' -> flushWord()
                    '|', ';', '<', '>', '&' -> {
                        flushWord()
                        val next = if (i + 1 < line.length) line[i + 1] else ' '
                        when {
                            ch == '&' && next == '&' -> { tokens.add(Token.Op("&&")); i++ }
                            ch == '|' && next == '|' -> { tokens.add(Token.Op("||")); i++ }
                            ch == '>' && next == '>' -> { tokens.add(Token.Op(">>")); i++ }
                            ch == '&' -> throw ShellError("no job control (&)")
                            else -> tokens.add(Token.Op(ch.toString()))
                        }
                    }
                    else -> current.append(ch)
                }
            }
            i++
        }
        if (quote != Quote.NONE) throw ShellError("unclosed quote")
        flushWord()
        return tokens
    }

    // MARK: - Expansion

    private fun expandVariables(text: String): String {
        val out = StringBuilder()
        var i = 0
        while (i < text.length) {
            val ch = text[i]
            if (ch == '$' && i + 1 < text.length) {
                val next = text[i + 1]
                if (next == '?') { out.append(lastStatus); i += 2; continue }
                if (next == '{') {
                    val close = text.indexOf('}', i + 2)
                    if (close >= 0) { out.append(env[text.substring(i + 2, close)] ?: ""); i = close + 1; continue }
                } else {
                    var j = i + 1
                    while (j < text.length && (text[j].isLetterOrDigit() || text[j] == '_')) j++
                    if (j > i + 1) { out.append(env[text.substring(i + 1, j)] ?: ""); i = j; continue }
                }
            }
            out.append(ch); i++
        }
        return out.toString()
    }

    private fun expand(parts: List<WordPart>, context: Context): List<String> {
        val text = StringBuilder()
        val globbable = StringBuilder()
        parts.forEachIndexed { index, part ->
            var piece = if (part.quote == Quote.SINGLE) part.text else expandVariables(part.text)
            if (part.quote == Quote.NONE && index == 0 && piece.startsWith("~")) piece = "/" + piece.drop(1)
            text.append(piece)
            globbable.append(if (part.quote == Quote.NONE) piece else " ".repeat(piece.length))
        }
        var hasGlob = false
        for (k in text.indices) {
            if (globbable[k] != ' ' && (text[k] == '*' || text[k] == '?' || text[k] == '[')) { hasGlob = true; break }
        }
        if (hasGlob) {
            val matches = glob(text.toString(), context)
            if (matches.isNotEmpty()) return matches
        }
        return listOf(text.toString())
    }

    private fun glob(pattern: String, context: Context): List<String> {
        val slash = pattern.lastIndexOf('/')
        val dirPattern = if (slash >= 0) pattern.substring(0, slash) else "."
        val namePattern = if (slash >= 0) pattern.substring(slash + 1) else pattern
        val dir = resolve(if (dirPattern.isEmpty()) "/" else dirPattern, context) ?: return emptyList()
        val entries = dir.file.listFiles() ?: return emptyList()
        val prefix = if (dirPattern == ".") "" else "$dirPattern/"
        val regex = globToRegex(namePattern)
        return entries.map { it.name }.filter { !it.startsWith(".") && regex.matches(it) }.sorted().map { prefix + it }
    }

    private fun globToRegex(pattern: String): Regex {
        val sb = StringBuilder("^")
        for (c in pattern) when (c) {
            '*' -> sb.append("[^/]*"); '?' -> sb.append("[^/]"); '[' -> sb.append('[')
            ']' -> sb.append(']'); '.' -> sb.append("\\."); else -> sb.append(Regex.escape(c.toString()))
        }
        sb.append("$")
        return Regex(sb.toString())
    }

    // MARK: - Pipeline

    private class Command { var argv = ArrayList<String>(); var stdinFile: String? = null; var stdoutFile: String? = null; var appendOut = false }
    private class IO(var out: String = "", var err: String = "", var status: Int = 0)

    private suspend fun runPipeline(tokens: List<Token>, context: Context): List<Output> {
        val commands = ArrayList<Command>()
        var command = Command()
        var pendingRedirect: String? = null
        for (token in tokens) {
            when (token) {
                is Token.Op -> when (token.value) {
                    "|" -> { commands.add(command); command = Command() }
                    ">", ">>", "<" -> pendingRedirect = token.value
                }
                is Token.Word -> {
                    val expanded = expand(token.parts, context)
                    if (pendingRedirect != null) {
                        val target = expanded.firstOrNull() ?: continue
                        when (pendingRedirect) {
                            ">" -> { command.stdoutFile = target; command.appendOut = false }
                            ">>" -> { command.stdoutFile = target; command.appendOut = true }
                            else -> command.stdinFile = target
                        }
                        pendingRedirect = null
                    } else command.argv.addAll(expanded)
                }
            }
        }
        if (pendingRedirect != null) { lastStatus = 2; return listOf(Output("msh: redirect needs a target", true)) }
        commands.add(command)

        val outputs = ArrayList<Output>()
        var pipe = ""
        for ((index, cmd) in commands.withIndex()) {
            if (cmd.argv.isEmpty()) { lastStatus = 2; return outputs }
            var stdin = pipe
            cmd.stdinFile?.let { file ->
                val target = resolve(file, context)
                val text = target?.file?.takeIf { it.exists() }?.readText()
                if (text == null) { lastStatus = 1; outputs.add(Output("msh: can't read $file", true)); return outputs }
                stdin = text
            }
            val isLast = index == commands.size - 1
            val mayStream = commands.size == 1 && cmd.stdoutFile == null && isLast
            val io = dispatch(cmd.argv, stdin, context, mayStream)
            if (io.err.isNotEmpty()) outputs.add(Output(io.err, true))
            val outFile = cmd.stdoutFile
            if (outFile != null) {
                write(io.out, outFile, cmd.appendOut, context)?.let { outputs.add(Output(it, true)); io.status = 1 }
            } else if (isLast) {
                val trimmed = io.out.removeSuffix("\n")
                if (trimmed.isNotEmpty()) outputs.add(Output(trimmed, false))
            } else pipe = io.out
            lastStatus = io.status
        }
        return outputs
    }

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

    private suspend fun dispatch(argv: List<String>, stdin: String, context: Context, streaming: Boolean): IO {
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
            "mkdir" -> mutate(args, context) { it.mkdirs() }
            "touch" -> touch(args, context)
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
            "xargs" -> dispatch((args.ifEmpty { listOf("echo") }) + stdin.split(Regex("\\s+")).filter { it.isNotEmpty() }, "", context, false)
            "base64" -> base64(args, stdin, context)
            "md5sum", "md5" -> checksum(args, stdin, context, "MD5")
            "sha256sum", "shasum" -> checksum(args, stdin, context, "SHA-256")
            // A real pager when the terminal can host one; cat into the scrollback when headless
            // or mid-pipeline. The Viewer stays the editor.
            "less", "more" -> {
                val content = cat(args, stdin, context)
                val launch = context.launchProgram
                if (!streaming || launch == null || content.err.isNotEmpty()) content
                else { launch(PagerProgram(content.out, argv.joinToString(" "))); IO() }
            }
            "sed" -> sed(args, stdin, context)
            "diff" -> diff(args, context)
            "date" -> IO(java.time.Instant.now().toString() + "\n")
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
            "sleep" -> sleepCmd(args)
            "ping" -> ping(args, context, streaming)
            "curl", "wget" -> curl(args, context)
            "pkg" -> pkgCmd(args, context)
            "git", "npm", "pnpm", "node", "npx" -> IO(err = "$name: not built yet — the native ${if (name == "git") "git" else "package"} engine is on the roadmap", status = 127)
            // A name the CATALOG claims answers honestly, installed or not — that is why the
            // catalog knows an uninstalled runtime's commands. "command not found" for a `python`
            // that is sitting on disk is simply false.
            else -> runtimeCmd(name, context) ?: IO(err = "msh: command not found: $name (type help)", status = 127)
        }
    }

    private val BUILTINS = setOf(
        "help", "clear", "pwd", "cd", "ls", "cat", "echo", "printf", "mkdir", "touch", "rm", "mv", "cp",
        "head", "tail", "wc", "sort", "uniq", "tr", "cut", "seq", "grep", "find", "nl", "rev", "tac",
        "tee", "xargs", "base64", "md5sum", "sha256sum", "sed", "diff", "date", "whoami", "true", "false",
        "env", "export", "unset", "history", "which", "basename", "dirname", "open", "sleep", "ping", "curl", "wget",
        "less", "more", "pkg",
    )

    private val HELP = """
        msh — built-ins:
          ls cd pwd cat echo printf mkdir touch rm mv cp head tail wc sort uniq
          tr cut seq grep find nl rev tac tee xargs base64 md5sum sha256sum
          sed 's/re/sub/g'  diff <a> <b>  ping [-c N] <host>  curl [-o f] <url>
          sleep  date  env  export NAME=v  unset  history (!!, !N)  which  open
          less <file>  (j/k space/b g/G q)
          pkg list | pkg install <runtime> | pkg remove <runtime>
        grammar: 'quotes' "with ${'$'}VARS"  |  > >> <  ;  &&  ||  ~  *  ?  ${'$'}?
        a streaming command (ping without -c) stops on any keypress
    """.trimIndent()

    /**
     * `pkg` — install a language runtime. A port of `pkgCmd` in Shell.swift, subcommand for
     * subcommand, because the two shells are meant to be the same shell.
     *
     * Nothing here knows a language by name: the catalog is `swift/Runtimes.json`, shared with
     * iOS, and adding language N+1 is a JSON entry and nothing else.
     */
    private suspend fun pkgCmd(args: List<String>, context: Context): IO {
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
                    // Off the main thread: this downloads tens of megabytes and inflates them.
                    // A multi-megabyte download with a silent terminal is indistinguishable from
                    // a hang, so each note lands in the scrollback as it happens.
                    withContext(Dispatchers.IO) {
                        support.store.install(entry, note = { context.emit(Output(it, false)) })
                    }
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
     * `WebAssembly` API, so a WebView supplies the wasm natively, but the launch path from msh
     * into the engine is milestone 3d and does not exist here yet. Saying so is better than
     * "command not found", which would be a lie about a 30 MB interpreter sitting on disk.
     */
    private fun runtimeCmd(name: String, context: Context): IO? {
        val support = context.runtimes ?: return null
        val entry = RuntimeCatalog.forCommand(support.catalog, name) ?: return null
        if (support.store.installed(entry) == null) {
            return IO(err = "$name: not installed — `pkg install ${entry.name}`", status = 127)
        }
        return IO(
            err = "$name: ${entry.name} ${entry.version} is installed, but running it needs the " +
                "Node layer's wasm host, which is not wired into msh yet",
            status = 127,
        )
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
        if (args.isEmpty()) return IO(stdin)
        val out = StringBuilder()
        for (file in args) {
            val target = resolve(file, context)?.file?.takeIf { it.exists() } ?: return IO(err = "cat: no such file: $file", status = 1)
            if (target.length() >= 400_000) return IO(err = "cat: file too large (${target.length() / 1024} KB)", status = 1)
            out.append(target.readText())
        }
        return IO(out.toString())
    }

    private fun printf(args: List<String>): IO {
        var format = args.firstOrNull()?.replace("\\n", "\n")?.replace("\\t", "\t") ?: return IO(err = "printf: usage: printf <format> [args…]", status = 1)
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

    private fun mutate(args: List<String>, context: Context, action: (File) -> Unit): IO {
        val target = resolve(args.firstOrNull() ?: return IO(err = "usage: needs a path", status = 1), context)
            ?: return IO(err = "invalid path", status = 1)
        return try { action(target.file); IO() } catch (e: Exception) { IO(err = "${e.message}", status = 1) }
    }

    private fun touch(args: List<String>, context: Context): IO {
        val target = resolve(args.firstOrNull() ?: return IO(err = "touch: usage: touch <file>", status = 1), context) ?: return IO(err = "touch: invalid path", status = 1)
        if (!target.file.exists()) { target.file.parentFile?.mkdirs(); target.file.createNewFile(); context.markModified(target.rel) }
        return IO()
    }

    private fun rm(args: List<String>, context: Context): IO {
        val recursive = args.contains("-r")
        val targets = args.filter { it != "-r" }
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
            args.contains("-l") -> IO("$lines\n"); args.contains("-w") -> IO("$words\n"); args.contains("-c") -> IO("$chars\n")
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
        val regex = if (isGlob) globToRegex(arg) else null
        val matches = ArrayList<String>()
        start.walkTopDown().onEnter { it.name != ".git" && it.name != "node_modules" }.forEach { f ->
            val hit = if (regex != null) regex.matches(f.name) else f.name.contains(arg, true)
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
        for (arg in args) { val eq = arg.indexOf('='); if (eq < 0) return IO(err = "export: usage: export NAME=value", status = 1); env[arg.substring(0, eq)] = arg.substring(eq + 1) }
        return IO()
    }

    private fun open(args: List<String>, context: Context): IO {
        val target = resolve(args.firstOrNull() ?: return IO(err = "open: usage: open <file>", status = 1), context) ?: return IO(err = "open: invalid path", status = 1)
        if (!target.file.isFile) return IO(err = "open: not a file: ${display(target.rel)}", status = 1)
        context.openFile(target.rel); return IO("opened ${display(target.rel)} in the viewer\n")
    }

    // MARK: - Streaming & network

    private suspend fun sleepCmd(args: List<String>): IO {
        val seconds = args.firstOrNull()?.toDoubleOrNull() ?: return IO(err = "sleep: usage: sleep <seconds>", status = 1)
        if (seconds < 0 || seconds > 3600) return IO(err = "sleep: out of range", status = 1)
        val end = System.currentTimeMillis() + (seconds * 1000).toLong()
        while (System.currentTimeMillis() < end && coroutineContext.isActive) kotlinx.coroutines.delay(50)
        return IO(status = if (coroutineContext.isActive) 0 else 130)
    }

    /**
     * Real reachability + RTT via `InetAddress.isReachable` (ICMP where the OS allows it, else a
     * TCP echo) — no raw sockets or NDK needed on Android. Solo it streams a line per second
     * until any keypress interrupts; in a pipeline it collects (default -c 4).
     */
    private suspend fun ping(args: List<String>, context: Context, streaming: Boolean): IO {
        var count: Int? = null; var host: String? = null
        val it = args.iterator()
        while (it.hasNext()) { val a = it.next(); if (a == "-c" && it.hasNext()) count = it.next().toIntOrNull() else if (!a.startsWith("-")) host = a }
        if (host == null) return IO(err = "ping: usage: ping [-c N] <host>", status = 1)
        val limit = count ?: if (streaming) Int.MAX_VALUE else 4
        val address = withContext(Dispatchers.IO) { runCatching { InetAddress.getByName(host) }.getOrNull() }
            ?: return IO(err = "ping: cannot resolve $host", status = 1)

        val collected = ArrayList<String>()
        fun line(text: String) { if (streaming) context.emit(Output(text, false)) else collected.add(text) }
        line("PING $host (${address.hostAddress}): reachability probe")
        var sent = 0; var received = 0
        while (sent < limit && coroutineContext.isActive) {
            sent++
            val start = System.nanoTime()
            val ok = withContext(Dispatchers.IO) { runCatching { address.isReachable(2000) }.getOrDefault(false) }
            if (!coroutineContext.isActive) break
            if (ok) { received++; line("reply from ${address.hostAddress}: seq=$sent time=%.2f ms".format((System.nanoTime() - start) / 1_000_000.0)) }
            else line("request timeout for seq $sent")
            if (sent < limit) { val elapsed = (System.nanoTime() - start) / 1_000_000; if (elapsed < 1000) kotlinx.coroutines.delay(1000 - elapsed) }
        }
        val loss = if (sent == 0) 0 else ((sent - received) * 100.0 / sent).toInt()
        line("--- $host ping statistics ---")
        line("$sent probes sent, $received reachable, $loss% loss")
        return IO(if (streaming) "" else joinLines(collected), status = if (received > 0) 0 else 1)
    }

    private suspend fun curl(args: List<String>, context: Context): IO {
        var outFile: String? = null; var urlString: String? = null
        val it = args.iterator()
        while (it.hasNext()) { val a = it.next(); if (a == "-o" && it.hasNext()) outFile = it.next() else if (!a.startsWith("-")) urlString = a }
        if (urlString == null) return IO(err = "curl: usage: curl [-o file] <url>", status = 1)
        if (!urlString.contains("://")) urlString = "https://$urlString"
        return withContext(Dispatchers.IO) {
            try {
                val connection = (URL(urlString).openConnection() as HttpURLConnection).apply { instanceFollowRedirects = true }
                val code = connection.responseCode
                val stream = if (code in 200..299) connection.inputStream else connection.errorStream
                val data = stream?.readBytes() ?: ByteArray(0)
                val errStatus = if (code >= 400) 22 else 0
                if (outFile != null) {
                    val target = resolve(outFile, context)
                    if (target == null || target.rel.isEmpty()) return@withContext IO(err = "curl: bad output path: $outFile", status = 1)
                    target.file.parentFile?.mkdirs(); target.file.writeBytes(data); context.markModified(target.rel)
                    IO("saved ${display(target.rel)} (${data.size} bytes, HTTP $code)\n", status = errStatus)
                } else if (data.size >= 400_000) IO("curl: response too large to print (${data.size / 1024} KB) — use -o <file>\n", status = errStatus)
                else IO(String(data), status = errStatus)
            } catch (e: Exception) { IO(err = "curl: ${e.message}", status = 7) }
        }
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
