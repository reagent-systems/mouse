package com.reagentsystems.mouse.nodehost

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.reagentsystems.mouse.node.NodeSmoke

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
 * The program and its grading are [NodeSmoke] — shared with `:nodecheck`, which runs the same
 * source under real `node`. That is what makes an on-device MISMATCH mean the WebView: the corpus
 * itself is already gated on the JVM.
 */
class NodeCheckReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        val pending = goAsync()
        val handler = Handler(Looper.getMainLooper())
        val stdout = StringBuilder()
        val stderr = StringBuilder()
        var settled = false
        var engine: NodeWebView? = null

        fun settle(failures: List<String>, checks: Int) {
            if (settled) return
            settled = true
            val verdict = if (failures.isEmpty()) {
                "NODE WEBVIEW: $checks checks — the bootstrap loads, console reaches Kotlin, " +
                    "process answers, timers and tick order, refusals by name — MATCH"
            } else {
                for (failure in failures) Log.e(TAG, "  FAIL: $failure")
                Log.e(TAG, "  stdout: ${stdout.toString().take(2000)}")
                Log.e(TAG, "  stderr: ${stderr.toString().take(2000)}")
                "NODE WEBVIEW: ${failures.size} of $checks checks failed — MISMATCH"
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
            settle(listOf("the engine did not finish within ${TIMEOUT_MS}ms"), NodeSmoke.CHECK_COUNT + 1)
        }, TIMEOUT_MS)

        engine = NodeWebView(
            context = context,
            config = NodeSmoke.CONFIG,
            output = object : NodeWebView.Output {
                override fun stdout(text: String) {
                    stdout.append(text)
                }

                override fun stderr(text: String) {
                    stderr.append(text)
                }

                override fun finished(code: Int) {
                    settle(
                        NodeSmoke.grade(stdout.toString(), stderr.toString(), code),
                        NodeSmoke.CHECK_COUNT + 1,
                    )
                }
            },
        )

        engine.start(NodeSmoke.PROGRAM, NodeSmoke.ENTRY_PATH) { error ->
            if (error != null) {
                settle(
                    listOf("the bootstrap loads in the WebView — ${error.take(600)}"),
                    NodeSmoke.CHECK_COUNT + 1,
                )
            }
        }
    }

    private companion object {
        const val TAG = "MouseNodeCheck"
        const val TIMEOUT_MS = 8_000L
    }
}
