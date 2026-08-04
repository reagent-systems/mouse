package com.reagentsystems.mouse.nodehost

import android.annotation.SuppressLint
import android.content.Context
import android.net.ConnectivityManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.webkit.ConsoleMessage
import android.webkit.JavascriptInterface
import android.webkit.WebChromeClient
import android.webkit.WebView
import android.webkit.WebViewClient
import com.reagentsystems.mouse.node.Bootstrap
import com.reagentsystems.mouse.node.EsmTranspiler
import com.reagentsystems.mouse.node.HostBridge
import com.reagentsystems.mouse.node.ModuleResolver
import com.reagentsystems.mouse.node.NodeCpu
import com.reagentsystems.mouse.node.NodeCrypto
import com.reagentsystems.mouse.packages.Json
import com.reagentsystems.mouse.node.NodeDns
import com.reagentsystems.mouse.node.NodeFs
import com.reagentsystems.mouse.node.NodeHttp
import com.reagentsystems.mouse.node.NodeKeys
import com.reagentsystems.mouse.node.NodeLoop
import com.reagentsystems.mouse.node.NodeProcessConfig
import com.reagentsystems.mouse.node.NodeSockets
import com.reagentsystems.mouse.node.NodeZlib
import java.io.File
import java.util.Base64

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
 * Milestones 3a, 3b and 3c. `console.log`/`error` reach Kotlin, `process` answers (argv, env, cwd,
 * version, exit code), timers run with node's tick discipline, the filesystem is real, `require`
 * resolves over `node_modules`, and `net`/`http`/`dns`/`dgram` ride a real Java NIO socket layer —
 * which is what makes a dev server inside the app possible. `fs.watch`, unix-domain sockets, the
 * `cluster` descriptor handoff, the `WebSocket` global, crypto, compression, `vm`, children and
 * workers refuse BY NAME, each with its own reason — see [HostBridge.DEFERRED].
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
    /**
     * Real directories grafted in at virtual prefixes. An installed runtime lives outside the
     * workspace — `python` is under `filesDir/runtimes`, not in the user's project — so without a
     * mount at `/usr/lib/python` its `.wasm` and its stdlib simply do not exist to any script.
     * Same list iOS builds; see `NodeFs.mount`.
     */
    mounts: List<Pair<String, File>> = emptyList(),
) {

    private val fs = NodeFs(root.toPath()).also {
        for ((prefix, real) in mounts) it.mount(prefix, real.toPath())
    }
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

    /**
     * The socket layer, and the two transports beside it.
     *
     * Each posts completions into the loop's JOB queue and schedules a pump; the loop drains jobs
     * FIRST, ahead of immediates and timers, which is the order `NodeEngine.runEventLoop` drains
     * them in. `retain`/`release` are the open-handle count — a listening server is a reason to
     * stay alive, an unref'd one is not.
     *
     * Not one of these runs I/O on the main thread, and on Android that is not tidiness: the
     * WebView's JavaScript runs on the main looper, so a blocking connect or lookup reached from
     * a `@JavascriptInterface` method would be a `NetworkOnMainThreadException` rather than a slow
     * answer. Every entry point hands the work to the selector thread or a resolver pool and
     * returns an id.
     */
    private val sockets = NodeSockets(
        post = ::postJob,
        retain = { hold(true) },
        release = { hold(false) },
    )
    /** One instance: `SecureRandom` reseeds itself, and constructing one per call is wasteful. */
    private val secureRandom = java.security.SecureRandom()

    private val dns = NodeDns(post = ::postJob)
    private val http = NodeHttp(post = ::postJob, retain = { hold(true) }, release = { hold(false) })

    private fun postJob(handlerId: Int, argsJson: String, final: Boolean) {
        loop.postJob(HostBridge.job(handlerId, argsJson, final))
        handler.post { pump() }
    }

    private fun hold(on: Boolean) {
        loop.hold(on)
        handler.post { pump() }
    }

    /**
     * The nameservers the `dns.resolve*` family asks.
     *
     * AGENTS.md: "Only the host knows what the host knows." Android has no `/etc/resolv.conf` —
     * `NodeDns`'s own fallback finds nothing there — and the active network's resolvers live
     * behind `ConnectivityManager`, which is framework and unreachable from `:node`. So the host
     * reads them and hands them down. On an emulator this is how a query reaches 10.0.2.3, the
     * NAT's resolver, rather than a guess.
     *
     * Empty is a legitimate answer (no network, or the permission refused): `NodeDns` then reports
     * ESERVFAIL rather than inventing a public resolver, which would send a user's lookups
     * somewhere they did not choose.
     */
    /**
     * What this machine actually is, for [Bootstrap.platformScript].
     *
     * `Build.SUPPORTED_ABIS` is Android's name for the architecture and node's is different, so
     * the first (preferred) ABI is translated rather than passed through: a package matching on
     * `process.arch` is looking for node's spelling, not the NDK's.
     */
    private fun platformScript(): String = Bootstrap.platformScript(
        platform = "android",
        type = "Linux",
        arch = when (Build.SUPPORTED_ABIS.firstOrNull()) {
            "arm64-v8a" -> "arm64"
            "armeabi-v7a", "armeabi" -> "arm"
            "x86_64" -> "x64"
            "x86" -> "ia32"
            else -> "arm64"
        },
        release = Build.VERSION.RELEASE ?: "",
    )

    private fun platformNameservers(): List<String> = try {
        val manager = appContext.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
        if (manager == null || Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            emptyList()
        } else {
            val active = manager.activeNetwork
            val properties = if (active == null) null else manager.getLinkProperties(active)
            properties?.dnsServers?.mapNotNull { it.hostAddress }.orEmpty()
        }
    } catch (_: Exception) {
        emptyList()
    }

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

        /**
         * Entropy, and the only crypto surface bound so far.
         *
         * It is here ahead of the rest of `crypto` because it is not really crypto's: CPython's
         * WASI start asks for it before `main` runs, so `python hello.py` cannot reach its first
         * line without it. `SecureRandom` is the platform's own CSPRNG — JCA, not a dependency —
         * and it is seeded by the OS, which is the property that matters. Base64 out, because the
         * bridge carries strings and the bootstrap already does `Buffer.from(…, 'base64')`.
         */
        // ---------------------------------------------------------- asymmetric keys ----
        //
        // Fourteen methods over one parser, per `NodeKeys`. Everything travels as PEM or base64
        // because that is what the bootstrap already holds; the three that answer a PAIR cross as
        // JSON, for the same reason `cipherSeal` does.

        @JavascriptInterface
        fun keyIdentify(pem: String): String {
            val identity = NodeKeys.identify(pem)
            return Json.write(
                mapOf(
                    "type" to identity.type,
                    "curve" to identity.curve,
                    "modulusLength" to identity.modulusLength,
                ),
            )
        }

        @JavascriptInterface
        fun keySign(pem: String, data: String, algorithm: String, raw: Boolean): String? =
            NodeKeys.sign(pem, data, algorithm, raw)

        @JavascriptInterface
        fun keyVerify(
            pem: String,
            data: String,
            signature: String,
            algorithm: String,
            raw: Boolean,
        ): Boolean = NodeKeys.verify(pem, data, signature, algorithm, raw)

        @JavascriptInterface
        fun keyGenerate(kind: String, curve: String): String? {
            val (public, private) = NodeKeys.generate(kind, curve) ?: return null
            return Json.write(mapOf("publicKey" to public, "privateKey" to private))
        }

        @JavascriptInterface
        fun keyAgree(privatePem: String, publicPem: String): String? =
            NodeKeys.agree(privatePem, publicPem)

        @JavascriptInterface
        fun ecdhGenerate(curve: String): String? {
            val (private, public) = NodeKeys.ecdhGenerate(curve) ?: return null
            return Json.write(mapOf("privateKey" to private, "publicKey" to public))
        }

        @JavascriptInterface
        fun ecdhCompute(curve: String, privateKey: String, peer: String): String? =
            NodeKeys.ecdhCompute(curve, privateKey, peer)

        @JavascriptInterface
        fun rsaGenerate(modulusLength: Int): String? {
            val (public, private) = NodeKeys.rsaGenerate(modulusLength) ?: return null
            return Json.write(mapOf("publicKey" to public, "privateKey" to private))
        }

        @JavascriptInterface
        fun rsaSign(pem: String, data: String, algorithm: String, pss: Boolean): String? =
            NodeKeys.rsaSign(pem, data, algorithm, pss)

        @JavascriptInterface
        fun rsaVerify(
            pem: String,
            data: String,
            signature: String,
            algorithm: String,
            pss: Boolean,
        ): Boolean = NodeKeys.rsaVerify(pem, data, signature, algorithm, pss)

        @JavascriptInterface
        fun rsaEncrypt(pem: String, data: String, padding: Int, digest: String): String? =
            NodeKeys.rsaEncrypt(pem, data, padding, digest)

        @JavascriptInterface
        fun rsaDecrypt(pem: String, data: String, padding: Int, digest: String): String? =
            NodeKeys.rsaDecrypt(pem, data, padding, digest)

        @JavascriptInterface
        fun rsaPrivateEncrypt(pem: String, data: String): String? =
            NodeKeys.rsaPrivateEncrypt(pem, data)

        @JavascriptInterface
        fun rsaPublicDecrypt(pem: String, data: String): String? =
            NodeKeys.rsaPublicDecrypt(pem, data)

        /**
         * `{data, tag}` as JSON, or null. The bridge cannot carry an object, and the bootstrap
         * reads `result.tag` and `result.data` — so the shim parses this back into the shape iOS
         * hands JavaScriptCore directly.
         */
        @JavascriptInterface
        fun cipherSeal(
            algorithm: String,
            key: String,
            iv: String,
            plain: String,
            aad: String,
        ): String? {
            val (data, tag) = NodeCrypto.cipherSeal(algorithm, key, iv, plain, aad) ?: return null
            return Json.write(mapOf("data" to data, "tag" to tag))
        }

        @JavascriptInterface
        fun cipherOpen(
            algorithm: String,
            key: String,
            iv: String,
            body: String,
            tag: String,
            aad: String,
        ): String? = NodeCrypto.cipherOpen(algorithm, key, iv, body, tag, aad)

        @JavascriptInterface
        fun zlibTransform(mode: String, base64: String, level: Int): String? =
            NodeZlib.transform(mode, base64, level)

        @JavascriptInterface
        fun zlibOpen(mode: String): Int = NodeZlib.open(mode)

        @JavascriptInterface
        fun zlibPush(handle: Int, base64: String, finish: Boolean): String? =
            NodeZlib.push(handle, base64, finish)

        @JavascriptInterface
        fun zlibClose(handle: Int) = NodeZlib.close(handle)

        /**
         * The code-only `import(…)` rewrite, for source a program compiles at runtime. The same
         * scanner the module loader runs — not a second one, which is the point: a bundle that
         * carries JavaScript inside a string must not be edited either way round.
         */
        @JavascriptInterface
        fun rewriteImports(source: String): String = EsmTranspiler.rewriteDynamicImport(source)

        @JavascriptInterface
        fun randomUUID(): String = NodeCrypto.randomUUID()

        @JavascriptInterface
        fun cryptoHash(algorithm: String, base64: String): String? = NodeCrypto.hash(algorithm, base64)

        @JavascriptInterface
        fun cryptoHmac(algorithm: String, keyBase64: String, base64: String): String? =
            NodeCrypto.hmac(algorithm, keyBase64, base64)

        @JavascriptInterface
        fun pbkdf2(password: String, salt: String, iterations: Int, keyLength: Int, digest: String): String? =
            NodeCrypto.pbkdf2(password, salt, iterations, keyLength, digest)

        @JavascriptInterface
        fun randomBytes(count: Int): String {
            if (count <= 0) return ""
            val bytes = ByteArray(count)
            secureRandom.nextBytes(bytes)
            return Base64.getEncoder().encodeToString(bytes)
        }


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
        fun setRawMode(raw: Boolean) {
            // No longer a no-op: raw mode is one of the three triggers the engagement rule
            // watches for, and it is the only one the PROGRAM announces rather than draws.
            handler.post { onRawMode?.invoke(raw) }
        }

        // ---------------------------------------------------------------- sockets ----
        //
        // Each of these returns an ID SYNCHRONOUSLY and does its work elsewhere, because that is
        // the shape `net.connect` needs: JavaScript must have a handle to return before anything
        // has happened. Every outcome after that arrives as a job.
        //
        // The id is also the key `node-host.js` files the callback under, which is why it has to
        // come back from the call rather than with the first event.

        @JavascriptInterface
        fun netConnect(host: String, port: Int): Int = sockets.connect(host, port)

        @JavascriptInterface
        fun netListen(host: String, port: Int, backlog: Int): Int = sockets.listen(host, port, backlog)

        /**
         * The one that answers a value the caller acts on: false means the kernel queue is past
         * the high-water mark, which JavaScript turns into `write()`'s false and a wait for
         * `drain`. Backpressure is honest end to end only because this is not always true.
         */
        @JavascriptInterface
        fun netWrite(id: Int, base64: String): Boolean =
            sockets.write(id, Base64.getDecoder().decode(base64))

        @JavascriptInterface
        fun netEnd(id: Int) = sockets.end(id)

        @JavascriptInterface
        fun netDestroy(id: Int) = sockets.destroy(id)

        @JavascriptInterface
        fun netPause(id: Int) = sockets.pause(id)

        @JavascriptInterface
        fun netResume(id: Int) = sockets.resume(id)

        @JavascriptInterface
        fun netRef(id: Int, refed: Boolean) = sockets.setRef(id, refed)

        @JavascriptInterface
        fun netNoDelay(id: Int, on: Boolean) = sockets.setNoDelay(id, on)

        @JavascriptInterface
        fun netKeepAlive(id: Int, on: Boolean, delayMs: Int) = sockets.setKeepAlive(id, on)

        /** `dns.lookup` — getaddrinfo, on the resolver pool. */
        @JavascriptInterface
        fun netResolve(host: String, family: Int): Int {
            val id = sockets.claimExternalId()
            sockets.resolve(id, host, family)
            return id
        }

        // -------------------------------------------------------------------- dns ----

        @JavascriptInterface
        fun dnsResolve(name: String, type: String): Int {
            val id = sockets.claimExternalId()
            dns.resolve(id, name, type)
            return id
        }

        @JavascriptInterface
        fun dnsReverse(address: String): Int {
            val id = sockets.claimExternalId()
            dns.reverse(id, address)
            return id
        }

        @JavascriptInterface
        fun dnsService(address: String, port: Int): Int {
            val id = sockets.claimExternalId()
            dns.lookupService(id, address, port)
            return id
        }

        /**
         * The bootstrap giving back the loop handle a lookup took. Every `dns.resolve*` completion
         * calls it exactly once, which is why the handle is taken by the QUERY and released here
         * rather than when the answer is delivered — the iOS `pendingLookups` pair, unchanged.
         */
        @JavascriptInterface
        fun dnsDone() = hold(false)

        // ------------------------------------------------------------------- http ----

        @JavascriptInterface
        fun httpRequest(url: String, method: String, headersJson: String, bodyBase64: String): Int {
            val id = sockets.claimExternalId()
            http.request(id, url, method, headersJson, bodyBase64)
            return id
        }

        @JavascriptInterface
        fun httpStream(url: String, method: String, headersJson: String, bodyBase64: String): Int {
            val id = sockets.claimExternalId()
            http.stream(id, url, method, headersJson, bodyBase64)
            return id
        }

        // ------------------------------------------------------------------ dgram ----

        @JavascriptInterface
        fun dgramBind(host: String, port: Int, broadcast: Boolean): Int =
            sockets.bindDatagram(host, port, broadcast)

        @JavascriptInterface
        fun dgramSend(id: Int, base64: String, host: String, port: Int): Int {
            val callback = sockets.claimExternalId()
            sockets.sendDatagram(callback, id, Base64.getDecoder().decode(base64), host, port)
            return callback
        }

        /** Synchronous, and the empty string is SUCCESS — see the note in NodeSockets. */
        @JavascriptInterface
        fun dgramMembership(id: Int, group: String, interfaceName: String, join: Boolean): String =
            sockets.multicastMembership(id, group, interfaceName, join)

        @JavascriptInterface
        fun dgramOption(id: Int, ttl: Int, loopback: Int, interfaceName: String) =
            sockets.multicastOption(
                id,
                ttl = if (ttl < 0) null else ttl,
                loopback = if (loopback < 0) null else loopback == 1,
                interfaceName = interfaceName,
            )
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
        dns.servers = platformNameservers()

        web.webViewClient = object : WebViewClient() {
            private var loaded = false
            override fun onPageFinished(view: WebView, url: String) {
                // A document can finish more than once; the engine loads exactly once.
                if (loaded) return
                loaded = true
                load(source, entryPath, ready)
            }
        }
        web.webChromeClient = object : WebChromeClient() {
            override fun onConsoleMessage(message: ConsoleMessage): Boolean {
                if (message.messageLevel() == ConsoleMessage.MessageLevel.ERROR) {
                    val text = message.message() ?: ""
                    if (text.startsWith(REJECTION_PREFIX)) {
                        onUnhandledRejection(text.substring(REJECTION_PREFIX.length))
                        return true
                    }
                }
                return false
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
                        evaluateGuardedInJs(Bootstrap.KEEP_NATIVE_WASM, "mouse-keep-native-wasm") { keepError ->
                            if (failed(keepError, ready)) return@evaluateGuardedInJs
                            val call = "globalThis.__mouseEvalAsset(" +
                                HostBridge.jsString(Bootstrap.ASSET_NAME) + ")"
                            evaluate(call) { bootError ->
                                if (failed(bootError, ready)) return@evaluate
                                evaluateGuardedInJs(Bootstrap.RESTORE_NATIVE_WASM, "mouse-restore-native-wasm") { wasmError ->
                                    if (failed(wasmError, ready)) return@evaluateGuardedInJs
                                    evaluateGuardedInJs(platformScript(), "mouse-platform") { platformError ->
                                        if (failed(platformError, ready)) return@evaluateGuardedInJs
                                        ready(null)
                                        runEntry(source, entryPath)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /**
     * An unhandled promise rejection, arriving by the only route that carries one here.
     *
     * ## Why this comes through the console and not through the engine
     *
     * iOS gets these from JavaScriptCore's `JSGlobalContextSetUnhandledRejectionCallback` and hands
     * the bootstrap `(promise, reason)`, which is the signature `__mouseOnUnhandledRejection` is
     * written to. Nothing calls that function on Android, and the reason is measured rather than
     * assumed — see the `unhandledRejection` entry in [HostBridge.DEFERRED]. The DOM
     * `unhandledrejection` event is PRESENT (`addEventListener` is a function, assigning
     * `onunhandledrejection` sticks) and never fires: four rejection sites across three programs,
     * both registration styles, native V8 promises on the real window, 500 ms each, zero events.
     * Chromium detects every one of them anyway and reports it here, as
     * `Uncaught (in promise) Error: boom`.
     *
     * ## What that buys, and what it does not
     *
     * The console carries a formatted STRING. node hands a handler the rejection's `reason` VALUE,
     * so this route can serve one half of node's contract and not the other, and the split is
     * exact:
     *
     *  - EXIT CODE — served in both branches. No `unhandledRejection` listener means the rejection
     *    is fatal: print, exit 1. A listener means node does NOT exit, and neither does this.
     *  - THE CALLBACK — not served. A program that registers a handler does not get called. The
     *    alternative is to synthesise an `Error` from the console text and pass it off as the
     *    reason, which a program cannot distinguish from the real one and which is wrong the
     *    moment something rejects with a string, a number, or an object carrying a `code`.
     *
     * So `bridge.unhandledRejection` stays DEFERRED — the engine-internal path really is unwired —
     * while the process-level behaviour a shell can observe is correct. The text printed is the
     * console message with its prefix removed, which for an `Error` is `Error: boom`, node's own
     * first stack line. There is no stack after it because the console message does not carry one.
     */
    private companion object {
        /** Chromium's own wording for a rejection nothing handled. */
        const val REJECTION_PREFIX = "Uncaught (in promise) "
    }

    private fun onUnhandledRejection(text: String) {
        if (ended) return
        // The query is read-only, but its completion can end the run, and a turn may not begin
        // between the two — the same window `inFlight` closes for every other bridge call.
        inFlight += 1
        evaluate("globalThis.process ? process.listenerCount('unhandledRejection') : 0") { raw ->
            inFlight -= 1
            val handlers = (unquote(raw) ?: raw ?: "0").trim().toIntOrNull() ?: 0
            if (handlers == 0 && !ended && loop.exitCode == null) {
                output.stderr(text + "\n")
                loop.exitCode = 1
            }
            // Teardown goes through the loop rather than straight to `end()`, so a rejection and a
            // turn already in flight cannot both tear down.
            pump()
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
        // The entry is transpiled HERE because it never passes through the resolver — msh reads
        // the file itself and hands the text over, so `loadJson`'s transpile never sees it. That
        // is exactly how `npx create-vite` failed: every module it required loaded fine and its
        // own bin, an ES module, did not.
        val isModule = entryPath.endsWith(".mjs") ||
            (!entryPath.endsWith(".cjs") && EsmTranspiler.looksLikeModule(source))
        val body = if (isModule) EsmTranspiler.transpile(source)
        else EsmTranspiler.rewriteDynamicImport(source)
        val call = "globalThis.__mouseDispatch.entry(" +
            HostBridge.jsString(body) + "," + HostBridge.jsString(entryPath) + "," + isModule + ")"
        inFlight += 1
        web.evaluateJavascript(call) { raw ->
            inFlight -= 1
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
     * The order is the iOS loop's order: every ready I/O completion as a batch, then every ready
     * immediate as a batch, then the earliest due timer, then sleep until the next one. JOBS COME
     * FIRST — that is `runEventLoop`'s own sequence (jobs, port deliveries, immediates, timers),
     * and it is what makes a socket's data reach its handler before a timer scheduled after it.
     * Quiescence — no queued job, no REF'D timer, no open handle, no live stdin listener — ends
     * the run, which is why an unref'd watchdog cannot keep a finished program alive.
     */
    private fun pump() {
        if (ended) return
        if (loop.exitCode != null) {
            end()
            return
        }
        // A turn may not begin while JavaScript from the previous one is still running.
        //
        // This is the consequence of the inversion in the class note. iOS's loop CALLS into
        // JavaScriptCore and gets its answer before the next line; here `evaluateJavascript` hands
        // the script to the WebView's renderer — a separate process — and returns, so the host's
        // view of the loop is stale for as long as the script runs. Any bridge call posts a pump,
        // and those posts land on the main looper while the renderer is still executing.
        //
        // Without this guard the loop asked `isQuiescent()` in that window and answered for a
        // program that had not finished starting: `net.createServer().listen()` on the first line
        // of a script reported exit 0 before the bind crossed the bridge. Nothing is lost by
        // returning here — whichever evaluation is in flight pumps again when it completes, and it
        // sees the state this pump would have read too early.
        if (inFlight > 0) return
        handler.removeCallbacks(pumpRunnable)

        // Time spent parked since the last turn is IDLE, exactly as the iOS loop counts the time
        // it sat in `wakeup.wait`. Cleared here so a pump that was NOT preceded by a park (a
        // bridge call posting one) contributes nothing.
        if (parkedSinceNanos != 0L) {
            loop.recordIdle(System.nanoTime() - parkedSinceNanos)
            parkedSinceNanos = 0L
        }

        val ready = loop.takeJobs()
        if (ready.isNotEmpty()) {
            dispatch(HostBridge.dispatchJobs(ready))
            return
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
        inFlight += 1
        web.evaluateJavascript(script) {
            inFlight -= 1
            loop.recordActive(System.nanoTime() - began)
            pump()
        }
    }

    /** When the loop parked, or 0 when it is running. Main thread only. */
    private var parkedSinceNanos = 0L

    /**
     * How many evaluations the host has handed the renderer and not yet heard back from. See the
     * guard in [pump]: while this is above zero the host's view of the loop is stale.
     */
    private var inFlight = 0


    private val pumpRunnable = Runnable { pump() }

    private fun end() {
        if (ended) return
        ended = true
        handler.removeCallbacks(pumpRunnable)
        releaseHandles()
        // iOS drains the tick queue once more after its `while` exits: the last callback's
        // microtask checkpoint has only just finished when the loop decides it is done.
        web.evaluateJavascript("globalThis.__mouseDispatch && globalThis.__mouseDispatch.finish();") {
            output.finished(loop.exitCode ?: 0)
        }
    }

    /**
     * Raw mode, as the running program asked for it. Set by whoever hosts the engine on a
     * screen; null when nothing is watching, which is every non-interactive run.
     */
    var onRawMode: ((Boolean) -> Unit)? = null

    /**
     * One keystroke into the program's stdin — data, never a signal. The host owns the terminal
     * discipline, which is why cooked-mode ^C goes to [interrupt] instead. `__mouseDeliverInput`
     * is the shared bootstrap's, so this is delivery and nothing else.
     */
    fun deliverInput(text: String) {
        if (ended) return
        handler.post {
            web.evaluateJavascript(
                "globalThis.__mouseDeliverInput && globalThis.__mouseDeliverInput(" +
                    HostBridge.jsString(text) + ")",
            ) { pump() }
        }
    }

    /** The visible grid changed size: `process.stdout.rows/columns` and a SIGWINCH. */
    fun resizeTty(rows: Int, columns: Int) {
        if (ended) return
        handler.post {
            web.evaluateJavascript("globalThis.__mouseResize && globalThis.__mouseResize($rows,$columns)") { pump() }
        }
    }

    /**
     * Cooked-mode ^C. A program with its own SIGINT handler keeps running — that is what
     * `__mouseSigint` answers — and one without it dies with node's 130.
     */
    fun interrupt() {
        if (ended) return
        handler.post {
            web.evaluateJavascript("String(!!(globalThis.__mouseSigint && globalThis.__mouseSigint()))") { raw ->
                val handled = unquote(raw) == "true"
                if (handled) pump() else {
                    loop.exitCode = 130
                    end()
                }
            }
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
        releaseHandles()
        web.destroy()
    }

    /**
     * Close every socket and stop every pool. This is `SocketTable.closeAll()`, and it exists for
     * one reason: a program that forgot to close its server must not outlive itself and hold the
     * port. On a phone the process persists between runs, so a leaked listener is not collected
     * the way it is when a CLI exits — the next run would fail with EADDRINUSE against a server
     * nobody can see.
     */
    private fun releaseHandles() {
        sockets.closeAll()
        dns.close()
        http.close()
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
        inFlight += 1
        web.evaluateJavascript(script) { raw ->
            inFlight -= 1
            then(unquote(raw))
        }
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
