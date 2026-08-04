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
import com.reagentsystems.mouse.node.ModuleResolver
import com.reagentsystems.mouse.node.NodeCpu
import com.reagentsystems.mouse.node.NodeFs
import com.reagentsystems.mouse.node.NodeLoop
import com.reagentsystems.mouse.node.NodeProcessConfig
import java.io.File

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
 * Milestones 3a and 3b. `console.log`/`error` reach Kotlin, `process` answers (argv, env, cwd,
 * version, exit code), timers run with node's tick discipline, the filesystem is real and
 * `require` resolves over `node_modules`. `fs.watch`, sockets, crypto, children and workers refuse
 * BY NAME, each with its own reason — see [HostBridge.DEFERRED].
 *
 * ## The filesystem a program sees
 *
 * Workspace-virtual, as on iOS: "/" is [root] and a program never learns where that really is.
 * On Android that is not only discipline — app-private storage lives at a path the user has no
 * name for, and a program that hardcoded it would break on the next install.
 */
class NodeWebView(
    context: Context,
    private val config: NodeProcessConfig = NodeProcessConfig(),
    /** The real directory the program's "/" maps to. */
    root: File,
    private val output: Output,
) {

    private val fs = NodeFs(root.toPath())
    private val resolver = ModuleResolver(fs)

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

        // ------------------------------------------------------------ filesystem ----
        //
        // Every one of these is SYNCHRONOUS on purpose: a `@JavascriptInterface` call blocks the
        // JavaScript thread until it returns, which is what `fs.readFileSync` is, and what the
        // bootstrap's async forms are built on top of (they call the same primitive and deliver
        // the answer through a timer). None of them touches the loop, so none needs the handler.
        //
        // A null String reaches JavaScript as `null`, which is exactly how the bootstrap is
        // written to hear "that failed" — see the note in node-host.js.

        @JavascriptInterface
        fun stat(path: String, followLinks: Boolean): String? = fs.statJson(path, followLinks)

        @JavascriptInterface
        fun statfs(path: String): String? = fs.statfsJson(path)

        @JavascriptInterface
        fun readdir(path: String): String? = fs.readdirJson(path)

        @JavascriptInterface
        fun readFile(path: String): String? = fs.readFile(path)

        /** The same bytes as text. The module loader wants source, not base64 of source. */
        @JavascriptInterface
        fun readText(path: String): String? = fs.readText(path)

        @JavascriptInterface
        fun writeFile(path: String, base64: String, append: Boolean): Boolean =
            fs.writeFile(path, base64, append)

        @JavascriptInterface
        fun mkdir(path: String): Boolean = fs.mkdir(path)

        @JavascriptInterface
        fun remove(path: String): Boolean = fs.remove(path)

        @JavascriptInterface
        fun rename(from: String, to: String): Boolean = fs.rename(from, to)

        @JavascriptInterface
        fun chmodPath(path: String, mode: Int): Boolean = fs.chmod(path, mode)

        @JavascriptInterface
        fun normalizePath(path: String): String = fs.normalize(path)

        @JavascriptInterface
        fun virtualDirname(path: String): String = fs.virtualDirname(path)

        // ------------------------------------------------------- module resolution ----

        @JavascriptInterface
        fun resolveModule(request: String, fromDir: String, esm: Boolean): String =
            resolver.resolveJson(request, fromDir, esm)

        @JavascriptInterface
        fun resolvePaths(request: String, fromDir: String): String =
            resolver.resolvePathsJson(request, fromDir)

        /**
         * Source plus the one classification the loader cannot make for itself.
         *
         * Read and classify in ONE crossing: the alternative is reading a megabyte-sized bundle
         * across the bridge and handing it straight back to be classified, and the rule for
         * whether a file is an ES module (`.mjs`, `.cjs`, the nearest package.json "type", the
         * syntax) then has two homes that can disagree.
         */
        @JavascriptInterface
        fun loadModule(id: String): String? = resolver.loadJson(id)

        // ------------------------------------------------------------- the machine ----

        /** `{user, system}` in microseconds, as `process.cpuUsage()` reports it. */
        @JavascriptInterface
        fun cpuUsage(): String {
            val usage = NodeCpu.read()
            // Zeros are what the iOS block answers when `getrusage` fails, so a caller meets one
            // shape of failure rather than two.
            return """{"user":${usage?.userMicros ?: 0.0},"system":${usage?.systemMicros ?: 0.0}}"""
        }

        /** `{idle, active}` in milliseconds, as `performance.eventLoopUtilization()` reads it. */
        @JavascriptInterface
        fun loopUtilization(): String {
            val (idle, active) = loop.utilizationMillis()
            return """{"idle":$idle,"active":$active}"""
        }

        /**
         * A headless host owns no terminal, so raw mode has nothing to change — the same thing
         * `NodeEngine`'s block does when `tty == nil`. When the T↔G join lands on Android this is
         * where the screen gets told.
         */
        @JavascriptInterface
        fun setRawMode(raw: Boolean) = Unit
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

        // Time spent parked since the last turn is IDLE, exactly as the iOS loop counts the time
        // it sat in `wakeup.wait`. Cleared here so a pump that was NOT preceded by a park (a
        // bridge call posting one) contributes nothing.
        if (parkedSinceNanos != 0L) {
            loop.recordIdle(System.nanoTime() - parkedSinceNanos)
            parkedSinceNanos = 0L
        }

        val batch = loop.takeImmediates()
        if (batch.isNotEmpty()) {
            dispatch(HostBridge.dispatchImmediate(batch))
            return
        }

        val due = loop.claimDue(System.nanoTime())
        if (due != null) {
            dispatch(HostBridge.dispatchTimer(due.id))
            return
        }

        if (loop.isQuiescent()) {
            end()
            return
        }

        // Only unref'd timers may be left here. They still FIRE — they are just not a reason to
        // stay alive, which isQuiescent() above has already decided.
        val wait = loop.nextWaitMillis(System.nanoTime())
        if (wait != null) {
            parkedSinceNanos = System.nanoTime()
            handler.postDelayed(pumpRunnable, wait.coerceAtLeast(1L))
        } else {
            // Nothing is scheduled and a hold is keeping the loop open; releasing it pumps. That
            // wait is idle too — it is the branch iOS spends in `wakeup.wait(timeout: .now() + 60)`.
            parkedSinceNanos = System.nanoTime()
        }
    }

    /**
     * One turn, timed. ACTIVE is the callback's own time, which is what the iOS `invoke` wrapper
     * measures — the loop's decision-making either side of it is neither idle nor active on both
     * platforms.
     */
    private fun dispatch(script: String) {
        val began = System.nanoTime()
        web.evaluateJavascript(script) {
            loop.recordActive(System.nanoTime() - began)
            pump()
        }
    }

    /** When the loop parked, or 0 when it is running. Main thread only. */
    private var parkedSinceNanos = 0L

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
