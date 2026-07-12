package com.reagentsystems.mouse

import androidx.compose.runtime.mutableStateListOf
import java.io.BufferedWriter
import java.io.File

/**
 * A real shell session: a persistent `/system/bin/sh` process with its stdin held open, so
 * state (cwd, variables, functions) survives between commands exactly like a desktop terminal.
 * This is the Android side of Mouse's terminal story — where iOS has no fork/exec and gets a
 * from-scratch shell (`msh`), Android apps may run the platform shell (toybox), so the "sh"
 * engine here is the genuine article.
 *
 * Output (stdout+stderr merged) streams onto [lines] from a reader thread; writes hop through
 * [send] on the caller's thread. Scrollback is capped like the iOS session.
 */
class ShellSession(workingDir: File) {
    val lines = mutableStateListOf<String>()

    private val process: Process = ProcessBuilder("/system/bin/sh")
        .directory(workingDir)
        .redirectErrorStream(true)
        .start()

    private val stdin: BufferedWriter = process.outputStream.bufferedWriter()

    init {
        Thread {
            process.inputStream.bufferedReader().forEachLine { line ->
                synchronized(lines) {
                    lines.add(line)
                    while (lines.size > 500) lines.removeAt(0)
                }
            }
            lines.add("[shell exited]")
        }.apply { isDaemon = true }.start()
    }

    /** Echo the command into scrollback (prompt-style), then hand it to the shell. */
    fun send(command: String) {
        lines.add("$ $command")
        runCatching {
            stdin.write(command)
            stdin.newLine()
            stdin.flush()
        }.onFailure { lines.add("[shell gone: ${it.message}]") }
    }

    fun destroy() = process.destroy()
}
