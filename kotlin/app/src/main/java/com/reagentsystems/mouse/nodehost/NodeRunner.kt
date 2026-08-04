package com.reagentsystems.mouse.nodehost

import android.content.Context
import android.os.Handler
import android.os.Looper
import com.reagentsystems.mouse.node.NodeProcessConfig
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * Run one JavaScript program to completion and answer its exit code.
 *
 * ## Why this class exists at all
 *
 * Two schedules that cannot be reconciled by wishing. `MouseShell` is blocking and coroutine-free
 * — that is deliberate, it is what lets `:shellcheck` run the shell against the real `/bin/sh`
 * with no emulator — and it runs on `Dispatchers.IO`. [NodeWebView] is the exact opposite: a
 * WebView belongs to the thread that created it, that thread must be the main looper, and its
 * whole loop is one `Handler` message per turn.
 *
 * So the engine is created and driven on the main thread while the shell's thread waits on a
 * latch, and output crosses back as it arrives rather than at the end. A program that prints for
 * an hour prints for an hour; nothing is buffered until exit.
 *
 * ## What it must not do
 *
 * Block the main thread. The latch is awaited on the CALLER's thread — never the main one — and
 * the check is written as a `require`, not a comment, because getting it wrong is an ANR that
 * looks like a hang in the terminal rather than a crash anyone can read.
 */
object NodeRunner {

    /** Where a running program's output goes, as it is produced. Called on the main thread. */
    fun interface Sink {
        fun write(text: String, isError: Boolean)
    }

    /**
     * Evaluate [source] as the entry module at [path] and block until it exits.
     *
     * [cancelled] is polled while the program runs: msh hands in its own `isActive`, so a
     * keystroke stops a dev server the same way it stops `ping`. A cancelled program is destroyed
     * rather than asked to leave — there is no signal to send a WebView — and answers 130, the
     * status a shell gives anything killed by SIGINT.
     */
    fun run(
        context: Context,
        source: String,
        path: String,
        config: NodeProcessConfig,
        root: File,
        mounts: List<Pair<String, File>> = emptyList(),
        sink: Sink,
        cancelled: () -> Boolean = { false },
        /**
         * Hand the program the terminal. Null for a plain run; supplied when the caller can host
         * a [NodeProgram] on the phase-T screen, which is what lets a TUI draw.
         */
        host: ((NodeProgram) -> Unit)? = null,
        title: String = "node",
    ): Int {
        require(Looper.myLooper() != Looper.getMainLooper()) {
            "NodeRunner.run blocks; calling it on the main thread is an ANR"
        }
        val handler = Handler(Looper.getMainLooper())
        val done = CountDownLatch(1)
        val code = intArrayOf(0)
        val engine = arrayOfNulls<NodeWebView>(1)
        val program = arrayOfNulls<NodeProgram>(1)

        handler.post {
            val view = NodeWebView(
                context = context,
                config = config,
                root = root,
                mounts = mounts,
                output = object : NodeWebView.Output {
                    // With a host, output belongs to the PROGRAM: it decides per chunk whether
                    // the line goes to the scrollback or the grid, which is the engagement rule.
                    override fun stdout(text: String) {
                        val hosted = program[0]
                        if (hosted != null) hosted.write(text, false) else sink.write(text, false)
                    }

                    override fun stderr(text: String) {
                        val hosted = program[0]
                        if (hosted != null) hosted.write(text, true) else sink.write(text, true)
                    }

                    override fun finished(exit: Int) {
                        code[0] = exit
                        val hosted = program[0]
                        if (hosted != null) hosted.finished(exit) else done.countDown()
                    }
                },
            )
            engine[0] = view
            if (host != null) {
                val hosted = NodeProgram(
                    title = title,
                    engine = view,
                    transcript = { line, isError -> sink.write(line + "\n", isError) },
                    onExit = { done.countDown() },
                )
                program[0] = hosted
                host(hosted)
            }
            view.start(source, path) { error ->
                if (error != null) {
                    sink.write(error + "\n", true)
                    code[0] = 1
                    done.countDown()
                }
            }
        }

        // Polled rather than awaited outright so cancellation is honoured while the program runs.
        while (!done.await(100, TimeUnit.MILLISECONDS)) {
            if (cancelled()) {
                handler.post { engine[0]?.destroy() }
                return 130
            }
        }
        handler.post { engine[0]?.destroy() }
        return code[0]
    }
}
