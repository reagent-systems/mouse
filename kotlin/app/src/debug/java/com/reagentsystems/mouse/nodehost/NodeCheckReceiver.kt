package com.reagentsystems.mouse.nodehost

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.reagentsystems.mouse.node.NodeFsSmoke
import com.reagentsystems.mouse.node.NodeProcessConfig
import com.reagentsystems.mouse.node.NodeSmoke
import java.io.File

/**
 * The on-device half of the Node layer's gate. DEBUG BUILDS ONLY (src/debug/AndroidManifest.xml).
 *
 * `./gradlew :nodecheck:run` grades everything about this layer a JVM can reach: the bootstrap's
 * drift from `swift/Mouse/NodeEngine.swift`, the bridge partition, the process globals, the event
 * loop's bookkeeping, and a load smoke through the real protocol under real `node`. What it
 * cannot reach is the WebView — `android.webkit` is framework — and the WebView is where the
 * engine actually runs. So this exists, and the orchestrator runs it:
 *
 * ```sh
 * adb shell am broadcast \
 *   -n com.reagentsystems.mouse/com.reagentsystems.mouse.nodehost.NodeCheckReceiver \
 *   -a com.reagentsystems.mouse.NODECHECK
 * ```
 *
 * `am broadcast` prints the verdict as the result data. It is also logged under `MouseNodeCheck`,
 * with one line per failing check ahead of it:
 *
 * ```sh
 * adb logcat -d -s MouseNodeCheck
 * ```
 *
 * The programs and their grading are [NodeSmoke] and [NodeFsSmoke] — shared with `:nodecheck`,
 * which runs the same sources under real `node`. That is what makes an on-device MISMATCH mean the
 * WebView: the corpus itself is already gated on the JVM.
 *
 * Two programs run in sequence, each in its own engine:
 *
 *  - [NodeSmoke] — console, `process`, timers and the tick order. It must be the FIRST thing its
 *    engine runs, because `__leaveEntryFrame` flips `hostFrame` false for good afterwards.
 *  - [NodeFsSmoke] — the filesystem and `require` over `node_modules`, which is the half no JVM
 *    harness can reach at all: `:nodecheck` grades `NodeFs` and `ModuleResolver` directly and
 *    grades the JavaScript loader against a stand-in host, and only here do the two meet.
 */
class NodeCheckReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        val pending = goAsync()
        val handler = Handler(Looper.getMainLooper())
        var settled = false
        var engine: NodeWebView? = null
        val total = NodeSmoke.CHECK_COUNT + NodeFsSmoke.CHECK_COUNT + 2

        fun settle(failures: List<String>, transcript: String) {
            if (settled) return
            settled = true
            val verdict = if (failures.isEmpty()) {
                "NODE WEBVIEW: $total checks — the bootstrap loads, console reaches Kotlin, " +
                    "process answers, timers and tick order, the filesystem round-trips, " +
                    "require resolves over node_modules, refusals by name — MATCH"
            } else {
                for (failure in failures) Log.e(TAG, "  FAIL: $failure")
                Log.e(TAG, transcript.take(4000))
                "NODE WEBVIEW: ${failures.size} of $total checks failed — MISMATCH"
            }
            Log.i(TAG, verdict)
            pending.resultCode = if (failures.isEmpty()) 0 else 1
            pending.resultData = verdict
            engine?.destroy()
            pending.finish()
        }

        // A hang is a worse bug than an error (AGENTS.md), and a broadcast that never finishes is
        // an ANR rather than a verdict. Every async probe gets a fallback timer.
        handler.postDelayed({
            settle(listOf("the engine did not finish within ${TIMEOUT_MS}ms"), "")
        }, TIMEOUT_MS)

        /**
         * Run one program, in a filesystem of its own. The root is emptied first: a check that
         * passed only because the previous run left a tree behind is a check that proves nothing,
         * and this one WRITES the tree it then requires.
         */
        fun runProgram(
            name: String,
            config: NodeProcessConfig,
            program: String,
            entryPath: String,
            grade: (String, String, Int) -> List<String>,
            then: (List<String>, String) -> Unit,
        ) {
            val stdout = StringBuilder()
            val stderr = StringBuilder()
            val root = File(context.cacheDir, "nodecheck/$name")
            root.deleteRecursively()
            root.mkdirs()

            fun transcript() = "  [$name] stdout: $stdout\n  [$name] stderr: $stderr"

            engine?.destroy()
            val next = NodeWebView(
                context = context,
                config = config,
                root = root,
                output = object : NodeWebView.Output {
                    override fun stdout(text: String) {
                        stdout.append(text)
                    }

                    override fun stderr(text: String) {
                        stderr.append(text)
                    }

                    override fun finished(code: Int) {
                        then(grade(stdout.toString(), stderr.toString(), code), transcript())
                    }
                },
            )
            engine = next
            next.start(program, entryPath) { error ->
                if (error != null) {
                    settle(listOf("the bootstrap loads in the WebView ($name) — ${error.take(600)}"), transcript())
                }
            }
        }

        runProgram("basic", NodeSmoke.CONFIG, NodeSmoke.PROGRAM, NodeSmoke.ENTRY_PATH, NodeSmoke::grade) { basic, first ->
            if (basic.isNotEmpty()) {
                settle(basic, first)
            } else {
                runProgram("fs", NodeFsSmoke.CONFIG, NodeFsSmoke.PROGRAM, NodeFsSmoke.ENTRY_PATH, NodeFsSmoke::grade) { fs, second ->
                    settle(fs, first + "\n" + second)
                }
            }
        }
    }

    private companion object {
        const val TAG = "MouseNodeCheck"

        /** Two engines, each loading 14,000 lines of bootstrap, on an emulator. */
        const val TIMEOUT_MS = 20_000L
    }
}
