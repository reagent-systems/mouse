package com.reagentsystems.mouse.nodehost

import android.annotation.SuppressLint
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.webkit.JavascriptInterface
import android.webkit.WebView
import android.webkit.WebViewClient
import com.reagentsystems.mouse.node.Bootstrap
import com.reagentsystems.mouse.node.HostBridge
import com.reagentsystems.mouse.node.NodeLoop
import com.reagentsystems.mouse.node.NodeProcessConfig

/**
 * The Node layer's host on Android: a headless WebView running the SAME JavaScript bootstrap the
 * iOS engine runs, with a Kotlin bridge underneath it.
 *
 * ## Why a WebView, and why this class cannot be in a gateable module
 *
 * `plans/android-parity.md` chose path B: the engine's bootstrap is ~72 % of it and portable, the
 * host bridge is the 28 % that gets rewritten per platform. Android forbids executing a
 * downloaded binary out of app-private storage (SELinux, API 29+), so shipping real `node` would
 * mean freezing the runtime set into the APK — exactly what the iOS side refused ("runtimes are
 * installed as data, never bundled"). A WebView gives a JIT for free and keeps runtimes as data.
 *
 * `android.webkit.WebView` is framework, so this class cannot live in a pure-JVM module and
 * `:nodecheck` cannot reach it. Everything around it that CAN be pure is: the bootstrap
 * extraction and its drift gate, the bridge protocol, the process globals and the event loop's
 * bookkeeping all live in `:node`. What is left here is DELIVERY — threads,
 * `evaluateJavascript`, the `@JavascriptInterface` object — and that is what the on-device check
 * (`NodeCheckReceiver`, debug builds only) exercises.
 *
 * ## Threads
 *
 * A WebView belongs to the thread that created it and its JavaScript runs there; this class
 * requires that to be the main looper. `@JavascriptInterface` methods do NOT arrive on it — the
 * WebView dispatches them onto its own JavaBridge thread — so everything they touch is either
 * synchronized ([NodeLoop]) or posted back through [handler].
 *
 * The iOS engine's event loop is a blocking `while` on a background queue. That shape is not
 * available here: a blocking loop on the main thread is an ANR, and the WebView's JavaScript
 * cannot run anywhere else. So the loop is inverted — one `Handler` message per turn — while
 * every decision it makes stays in [NodeLoop], where a harness can reach it.
 *
 * ## Scope
 *
 * Milestone 3a. `console.log`/`error` reach Kotlin, `process` answers (argv, env, cwd, version,
 * exit code) and timers run with node's tick discipline. `fs`, `require`, sockets, crypto,
 * children and workers refuse BY NAME — see [HostBridge.DEFERRED].
 */
class NodeWebView(
    context: Context,
    private val config: NodeProcessConfig = NodeProcessConfig(),
    private val output: Output,
) {

    /** Where a program's stdout and stderr go. Called on the main thread. */
    interface Output {
        fun stdout(text: String)
        fun stderr(text: String)

        /** The run ended: `process.exit`'s code, or 0 when the loop simply emptied. */
        fun finished(code: Int)
    }

    private val handler = Handler(Looper.getMainLooper())
    private val loop = NodeLoop()
    private val appContext = context.applicationContext

    private var started = false
    private var ended = false

    @SuppressLint("SetJavaScriptEnabled")
    private val web: WebView = WebView(appContext).also {
        it.settings.javaScriptEnabled = true
        // Nothing is ever fetched and nothing is ever shown: the document is a blank page whose
        // only job is to give the JS context somewhere to live.
        it.settings.domStorageEnabled = false
        it.settings.allowFileAccess = false
        it.settings.allowContentAccess = false
        it.addJavascriptInterface(HostObject(), HostBridge.HOST_OBJECT)
    }

    // ------------------------------------------------------------------ the bridge ----

    /**
     * The `@JavascriptInterface` surface — `__mouseHost` in JavaScript. Strings and primitives
     * only, in both directions; that limit is the whole reason `node-host.js` exists.
     *
     * Every method here runs on the WebView's JavaBridge thread.
     */
    private inner class HostObject {

        /** The engine's own sources, by asset name. See the note in node-host.js. */
        @JavascriptInterface
        fun asset(name: String): String = readAsset(name)

        @JavascriptInterface
        fun stdout(text: String) {
            handler.post { output.stdout(text) }
        }

        @JavascriptInterface
        fun stderr(text: String) {
            handler.post { output.stderr(text) }
        }

        @JavascriptInterface
        fun exit(code: Int) {
            loop.exitCode = code
            handler.post { end() }
        }

        /** A decimal STRING, deliberately — see the note in node-host.js. */
        @JavascriptInterface
        fun monotonicNanos(): String = System.nanoTime().toString()

        @JavascriptInterface
        fun setTimer(delayMs: Double, repeat: Boolean): Int {
            val id = loop.setTimer(delayMs.toLong().coerceAtLeast(1L), repeat, System.nanoTime())
            handler.post { pump() }
            return id
        }

        @JavascriptInterface
        fun clearTimer(id: Int) = loop.clearTimer(id)

        @JavascriptInterface
        fun timerRef(id: Int, refed: Boolean) {
            loop.refTimer(id, refed)
            handler.post { pump() }
        }

        @JavascriptInterface
        fun timerRefresh(id: Int) {
            loop.refreshTimer(id, System.nanoTime())
            handler.post { pump() }
        }

        @JavascriptInterface
        fun setImmediate(): Int {
            val id = loop.setImmediate()
            handler.post { pump() }
            return id
        }

        @JavascriptInterface
        fun clearImmediate(id: Int) = loop.clearImmediate(id)

        @JavascriptInterface
        fun loopHold(on: Boolean) {
            loop.hold(on)
            handler.post { pump() }
        }

        @JavascriptInterface
        fun stdinActive(on: Boolean) {
            loop.stdinActive = on
            handler.post { pump() }
        }
    }

    // ------------------------------------------------------------------- lifecycle ----

    /**
     * Load the engine, then run [source] as the entry script. Main thread only.
     *
     * [ready] receives null once the bootstrap is live, or the failure text if any stage of the
     * load threw.
     */
    fun start(source: String, entryPath: String = "/main.js", ready: (String?) -> Unit = {}) {
        check(Looper.myLooper() == Looper.getMainLooper()) { "NodeWebView runs on the main looper" }
        check(!started) { "NodeWebView.start is once per instance" }
        started = true

        web.webViewClient = object : WebViewClient() {
            private var loaded = false
            override fun onPageFinished(view: WebView, url: String) {
                // A document can finish more than once; the engine loads exactly once.
                if (loaded) return
                loaded = true
                load(source, entryPath, ready)
            }
        }
        web.loadDataWithBaseURL("about:blank", "<!doctype html><html></html>", "text/html", "utf-8", null)
    }

    /**
     * The load order, and it is load-BEARING:
     *
     *  1. `node-host.js` — defines `__mouse` and `__mouseEval`.
     *  2. the deferred stubs — every bridge name with no Android binding, refusing by name.
     *  3. the global unlock — the WebView's global object is a `Window`, and some of what the
     *     bootstrap installs is already there as a getter with no setter. See
     *     [Bootstrap.unlockGlobalsScript]; without it the engine dies on `globalThis.crypto`.
     *  4. the process globals — `__argv`, `__env`, `__cwd`, … The bootstrap reads them at the top
     *     level of its IIFE (`argv: __argv.slice()`), so they must exist BEFORE it, not after.
     *  5. `node-bootstrap.js` — the engine.
     */
    private fun load(source: String, entryPath: String, ready: (String?) -> Unit) {
        // Read once for the unlock scan. The bootstrap crosses the bridge again by NAME when it
        // is evaluated, so the 700 KB is never embedded in a script literal.
        val unlock = Bootstrap.unlockGlobalsScript(readAsset(Bootstrap.ASSET_NAME))
        evaluate(guarded(readAsset(HostBridge.SHIM_ASSET_NAME), HostBridge.SHIM_ASSET_NAME)) { shimError ->
            if (failed(shimError, ready)) return@evaluate
            evaluateGuardedInJs(HostBridge.deferredStubScript(), "mouse-deferred-stubs") { stubError ->
                if (failed(stubError, ready)) return@evaluateGuardedInJs
                evaluateGuardedInJs(unlock, "mouse-unlock-globals") { unlockError ->
                    if (failed(unlockError, ready)) return@evaluateGuardedInJs
                    evaluateGuardedInJs(config.globalsScript(), "mouse-process-globals") { globalsError ->
                        if (failed(globalsError, ready)) return@evaluateGuardedInJs
                        val call = "globalThis.__mouseEvalAsset(" +
                            HostBridge.jsString(Bootstrap.ASSET_NAME) + ")"
                        evaluate(call) { bootError ->
                            if (failed(bootError, ready)) return@evaluate
                            ready(null)
                            runEntry(source, entryPath)
                        }
                    }
                }
            }
        }
    }

    private fun failed(error: String?, ready: (String?) -> Unit): Boolean {
        if (error == null) return false
        ready(error)
        output.stderr(error + "\n")
        loop.exitCode = 1
        end()
        return true
    }

    private fun runEntry(source: String, entryPath: String) {
        val call = "globalThis.__mouseDispatch.entry(" +
            HostBridge.jsString(source) + "," + HostBridge.jsString(entryPath) + ")"
        web.evaluateJavascript(call) { raw ->
            val text = unquote(raw) ?: ""
            if (text.contains("\"ok\":false")) {
                // A synchronous top-level throw is node's exit 1, printed. `process.exit` is not
                // one — the shim already filtered its sentinel out.
                val marker = "\"error\":\""
                val at = text.indexOf(marker)
                val message = if (at >= 0) text.substring(at + marker.length).trimEnd('"', '}') else text
                output.stderr(message.replace("\\n", "\n") + "\n")
                loop.exitCode = 1
                end()
            } else {
                pump()
            }
        }
    }

    /**
     * One turn of the event loop.
     *
     * The order is the iOS loop's order: every ready immediate as a batch, then the earliest due
     * timer, then sleep until the next one. Quiescence — no REF'D timer, no open handle, no live
     * stdin listener — ends the run, which is why an unref'd watchdog cannot keep a finished
     * program alive.
     */
    private fun pump() {
        if (ended) return
        if (loop.exitCode != null) {
            end()
            return
        }
        handler.removeCallbacks(pumpRunnable)

        val batch = loop.takeImmediates()
        if (batch.isNotEmpty()) {
            web.evaluateJavascript(HostBridge.dispatchImmediate(batch)) { pump() }
            return
        }

        val due = loop.claimDue(System.nanoTime())
        if (due != null) {
            web.evaluateJavascript(HostBridge.dispatchTimer(due.id)) { pump() }
            return
        }

        if (loop.isQuiescent()) {
            end()
            return
        }

        // Only unref'd timers may be left here. They still FIRE — they are just not a reason to
        // stay alive, which isQuiescent() above has already decided.
        val wait = loop.nextWaitMillis(System.nanoTime())
        if (wait != null) handler.postDelayed(pumpRunnable, wait.coerceAtLeast(1L))
        // Otherwise nothing is scheduled and a hold is keeping the loop open; releasing it pumps.
    }

    private val pumpRunnable = Runnable { pump() }

    private fun end() {
        if (ended) return
        ended = true
        handler.removeCallbacks(pumpRunnable)
        // iOS drains the tick queue once more after its `while` exits: the last callback's
        // microtask checkpoint has only just finished when the loop decides it is done.
        web.evaluateJavascript("globalThis.__mouseDispatch && globalThis.__mouseDispatch.finish();") {
            output.finished(loop.exitCode ?: 0)
        }
    }

    /** Evaluate JavaScript in the live engine. For the on-device check; the entry uses [start]. */
    fun eval(script: String, then: (String?) -> Unit) {
        web.evaluateJavascript(script) { then(unquote(it)) }
    }

    /** Release the WebView. The instance is dead afterwards. */
    fun destroy() {
        ended = true
        handler.removeCallbacks(pumpRunnable)
        web.destroy()
    }

    // ----------------------------------------------------------------------- detail ----

    private fun readAsset(name: String): String =
        appContext.assets.open(name).use { it.readBytes().toString(Charsets.UTF_8) }

    /** The bootstrap of the bootstrap: `__mouseEval` does not exist until the shim has run. */
    private fun guarded(script: String, label: String): String =
        "(function(){ try { (0, eval)(" + HostBridge.jsString(script + "\n//# sourceURL=" + label) +
            "); return null; } catch (e) { return String((e && e.stack) || e); } })()"

    private fun evaluateGuardedInJs(script: String, label: String, then: (String?) -> Unit) {
        evaluate(
            "globalThis.__mouseEval(" + HostBridge.jsString(script) + "," +
                HostBridge.jsString(label) + ")",
            then,
        )
    }

    private fun evaluate(script: String, then: (String?) -> Unit) {
        web.evaluateJavascript(script) { raw -> then(unquote(raw)) }
    }

    /** `evaluateJavascript` hands back its result JSON-encoded: `null`, or a quoted string. */
    private fun unquote(raw: String?): String? {
        if (raw == null || raw == "null" || raw == "undefined") return null
        if (raw.length >= 2 && raw.startsWith("\"") && raw.endsWith("\"")) {
            return raw.substring(1, raw.length - 1)
                .replace("\\n", "\n")
                .replace("\\t", "\t")
                .replace("\\r", "\r")
                .replace("\\\"", "\"")
                .replace("\\\\", "\\")
        }
        return raw
    }
}
