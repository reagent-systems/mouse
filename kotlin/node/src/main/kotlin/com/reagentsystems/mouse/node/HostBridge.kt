package com.reagentsystems.mouse.node

/**
 * The `__mouse` bridge protocol — the contract between the JS bootstrap and whatever host runs it.
 *
 * ## Why Android cannot reuse the iOS bridge shape
 *
 * On iOS the bridge is a dictionary of Swift blocks handed straight to JavaScriptCore, so the
 * bootstrap can pass a JS FUNCTION across it: `bridge.setTimer(fn, delay, repeat, args)` hands the
 * callback itself to the host, which calls it back later. Android's `@JavascriptInterface` cannot
 * carry a function — only primitives and strings cross it, in either direction.
 *
 * So the Android bridge is two layers instead of one:
 *
 *  - `__mouseHost` — the `@JavascriptInterface` object. Strings and numbers only. Its methods may
 *    return a value synchronously, which is what makes `monotonicNanos()` and `setTimer()` work at
 *    all (the bootstrap uses both results immediately).
 *  - `__mouse` — a JavaScript shim (`node-host.js`) that presents the iOS-shaped API to the
 *    bootstrap. Callbacks stay in JS, in a registry keyed by the id the host handed back; the host
 *    re-enters JS by evaluating [dispatchTimer] / [dispatchImmediate] against that registry.
 *
 * The bootstrap itself is untouched by any of this — that is the point.
 *
 * ## Why the name lists are here, in a pure module
 *
 * A bridge method the bootstrap calls and the host never defines is a `TypeError` thrown from
 * 14,000 lines of someone else's JavaScript, in the WebView, where nothing is watching. So every
 * name the bootstrap references is accounted for exactly once — [IMPLEMENTED] or [DEFERRED] — and
 * `:nodecheck` grades that partition against the names it finds in the SHIPPING bootstrap. When
 * the iOS engine grows a bridge method, the Android gate goes red and says which one.
 */
object HostBridge {

    /** The name the `@JavascriptInterface` object is registered under in the WebView. */
    const val HOST_OBJECT: String = "__mouseHost"

    /** Asset holding the JS shim that builds `__mouse` on top of [HOST_OBJECT]. */
    const val SHIM_ASSET_NAME: String = "node-host.js"

    /** Path, relative to the repo root, of that shim. */
    const val SHIM_ASSET_PATH: String = "kotlin/app/src/main/assets/node-host.js"

    /**
     * What the Android host binds for real.
     *
     * Milestone 3a brought everything a program needs to print, to be told who it is and to
     * schedule work; 3b brought the filesystem and the module loader, which is what turns the
     * engine from a thing that runs a string into a thing that runs a PROGRAM.
     */
    val IMPLEMENTED: Set<String> = linkedSetOf(
        // console.log / console.error and the process.stdout / process.stderr sinks under them
        "stdout",
        "stderr",
        // process.exit
        "exit",
        // timers
        "setTimer",
        "clearTimer",
        "timerRef",
        "timerRefresh",
        "setImmediate",
        "clearImmediate",
        // Called at TOP LEVEL by the bootstrap (`__perfStart`), so it cannot be a stub.
        "monotonicNanos",
        // Also called at top level (`globalThis.__mouseRequire`). It must RETURN a function, and
        // since 3b the function it returns is a real CommonJS `require` over node_modules.
        "createRequire",
        // Event-loop bookkeeping: an open handle and a live stdin listener each keep the loop
        // running.
        "loopHold",
        "stdinActive",
        // 3b — the filesystem. Primitives only: every rule about WHEN they may be called (ENOENT
        // for a missing parent, EISDIR, EEXIST, refusing to delete a tree without `recursive`)
        // lives in the shared bootstrap and comes across with it.
        "stat",
        "statfs",
        "readFile",
        "writeFile",
        "readdir",
        "mkdir",
        "remove",
        "rename",
        "chmodPath",
        // 3b — the process surface that reads the machine rather than the program.
        "cpuUsage",
        "loopUtilization",
        // A headless host has no terminal, so this does nothing — which is what the iOS block
        // does in the same configuration (`self?.tty?.rawModeChanged(raw)` with `tty == nil`).
        // It is a faithful port of a no-op, not a stub standing in for one.
        "setRawMode",
        // 3c — TCP, through `NodeSockets`' Java NIO table. `net` is the whole of what
        // `http.createServer` stands on, so this is the milestone that makes a dev server on the
        // device possible at all. Every RULE about half-close, backpressure and when a socket may
        // announce its own close lives in the shared bootstrap and comes across with it.
        "netConnect",
        "netListen",
        "netWrite",
        "netEnd",
        "netDestroy",
        "netPause",
        "netResume",
        "netRef",
        "netNoDelay",
        "netKeepAlive",
        // `dns.lookup` — getaddrinfo, which is `InetAddress.getAllByName`, on the resolver pool
        // and never on the thread that carries socket I/O.
        "netResolve",
        // 3c — the dns.resolve* family: a real DNS query on the wire (`NodeDns`), because no Java
        // API asks a nameserver for a record type and Android ships no JNDI at all.
        "dnsResolve",
        "dnsReverse",
        "dnsService",
        "dnsDone",
        // 3c — the TLS-capable transport behind `fetch` and `https.request`. Same bargain as iOS:
        // the platform owns the handshake (`HttpsURLConnection` there, URLSession here), and this
        // layer owns only delivery — including the incremental delivery that makes it a stream.
        "httpRequest",
        "httpStream",
        // 3c — UDP. The refusal that covered these named the missing socket layer; once the
        // selector exists, `DatagramChannel` is the same machinery with whole packets, so the
        // reason stopped being true and the capability had to follow it.
        "dgramBind",
        "dgramSend",
        "dgramOption",
        "dgramMembership",
        // Entropy, ahead of the rest of crypto and not really part of it: CPython's WASI start
        // asks for random bytes before a script's first line runs, so `python hello.py` cannot
        // reach `print` without it. `SecureRandom` is the platform's own CSPRNG — JCA, not a
        // dependency. Everything else on the crypto surface is still deferred, by name.
        "randomBytes",
        // 3d, the arithmetic half of crypto. CryptoKit on iOS, the JCA here — the platform's own
        // either way, so no dependency is added. What is still deferred below is the half that
        // needs KEY MANAGEMENT (Security framework has no JCA equivalent that maps one to one)
        // rather than the half that is a digest.
        "cryptoHash",
        "cryptoHmac",
        "pbkdf2",
        "randomUUID",
        // 3d — zlib. `java.util.zip` is the JDK's own, so no dependency; what it does NOT give is
        // zlib's `windowBits`, which on iOS selects the framing for free. gzip's header and
        // trailer, and the gzip-or-zlib auto-detect the `gunzip`/`inflate`/`unzip` modes need,
        // are written in `NodeZlib` instead. Brotli stays deferred below, and for a real reason.
        "zlibOpen",
        "zlibPush",
        "zlibClose",
        "zlibTransform",
        // 3d — symmetric ciphers. These take the key the CALLER supplies, so they are arithmetic
        // like the digests, not key management: AES-GCM, ChaCha20-Poly1305, and AES in CBC/CTR/ECB.
        // iOS splits them between CryptoKit's AEADs and CommonCrypto's block modes; the JCA has
        // all of it under one `Cipher`, with the transformation string doing that job.
        "cipherSeal",
        "cipherOpen",
        // 3d — `vm`. Implemented in the SHIM rather than in Kotlin, because the second context is
        // a JavaScript object: an about:blank iframe is same-origin, so its `contentWindow` is
        // reachable and has its own globals and intrinsics. The refusal here used to say a
        // WebView could not give one; it was measured on a device and it was wrong.
        "vmCreate",
        "vmRun",
        // 3e — the code-only rewrite of `import(…)`, for source compiled at RUNTIME. Its refusal
        // said "Android has no transpiler, which is also why require() of an ES module refuses";
        // 3e made both halves false and this was left behind. It is one line over
        // `EsmTranspiler`, which is the same rewriter the loader already runs.
        "rewriteImports",
    )

    /**
     * The rest of the iOS bridge: a name, and the REASON there is no Android binding behind it.
     *
     * The reason is the point. A missing member reads as `undefined is not a function` from inside
     * 14,000 lines of someone else's JavaScript with no clue attached; a silent no-op is worse
     * still (AGENTS.md: "a silent no-op is a lie"); and a refusal that names no reason, or names a
     * reason that has since stopped being true, is worse than all of them, because it stops
     * anyone looking again. So the reasons are per-SURFACE and they are graded — `:nodecheck`
     * calls every name here and fails if one answers, and calls the implemented ones and fails if
     * one refuses, so the claim cannot rot in either direction.
     */
    val DEFERRED: Map<String, String> = buildDeferred(
        // fs.watch is the one part of the filesystem that did not come with the rest, and the
        // wall is specific rather than "later": it is not a syscall, it is a subscription.
        listOf("fsWatch", "fsUnwatch") to
            "watching a path needs inotify, which on Android is `android.os.FileObserver` — " +
            "framework, so it cannot live in the pure module this bridge is partitioned in, and " +
            "the recursive mode node documents would be one observer per subdirectory plus one " +
            "per FILE, which is the only way inotify can name which entry changed",
        listOf("netConnectUnix", "netListenUnix") to
            "a socket FILE needs AF_UNIX, and the only `java.nio` spelling for it is " +
            "`java.net.UnixDomainSocketAddress` — JDK 16, and Android API 34, against this app's " +
            "minSdk 26, so on most devices it targets the class is simply absent; the framework " +
            "alternative `android.net.LocalSocket` is not a `SelectableChannel` and cannot join " +
            "the one selector every other socket here is driven by",
        listOf("netListenHandoff", "netAdopt", "netDiscard") to
            "these three are `cluster`'s seam: the primary accepts a connection and hands the raw " +
            "DESCRIPTOR to a worker engine in the same OS process. Android has no worker engines " +
            "yet, and `java.nio` gives no way to build a `SocketChannel` around a descriptor it " +
            "did not open — a channel owns its fd and will not adopt one",
        listOf("wsOpen", "wsSend", "wsClose") to
            "this is the `WebSocket` GLOBAL, which on iOS rides URLSession's own WebSocket task " +
            "because it is the one TLS-capable path there; neither the JDK nor the Android " +
            "framework ships a WebSocket client at all, so the choices are a third-party artifact " +
            "(invariant #4) or a hand-written RFC 6455 client that still could not do `wss://`. " +
            "The `ws` PACKAGE is unaffected — it rides these sockets for `ws://` and works",
        listOf(
            "scrypt", "hkdf",
            "keyGenerate", "keyIdentify", "keySign", "keyVerify",
            "keyAgree", "ecdhGenerate", "ecdhCompute", "rsaGenerate", "rsaSign", "rsaVerify",
            "rsaEncrypt", "rsaDecrypt", "rsaPrivateEncrypt", "rsaPublicDecrypt",
        ) to
            "asymmetric keys. The JCA HAS the primitives — `KeyPairGenerator`, `Signature`, " +
            "`KeyAgreement`, `KeyFactory` — so this is not a missing capability, and saying so " +
            "matters: the work is the KEYS, not the maths. Every one of these takes a PEM, and " +
            "reading one means PKCS#8, SEC1, PKCS#1 and SPKI, identifying the curve, and " +
            "emitting ECDSA signatures in DER or raw as the caller asks. Ed25519 adds its own " +
            "wall: the JCA gained it at API 33, against this app's minSdk 26. It is a port of " +
            "real size rather than a translation, which is why it is deferred and not merely " +
            "unwired",
        listOf(
            "brotliOpen", "brotliPush", "brotliClose", "brotliTransform",
        ) to
            "brotli rides Apple's Compression framework, which has carried it since iOS 15. " +
            "Android has no counterpart: the platform decodes brotli inside its HTTP stack and " +
            "exposes no encoder or decoder to an app, `java.util.zip` is DEFLATE only, and the " +
            "algorithm is a large one to hand-write for a static dictionary this would also have " +
            "to carry. A third-party artifact is the only other route and invariant #4 forbids " +
            "it. zlib itself IS bound — see `NodeZlib`",

        listOf(
            "shellExec", "spawnNode", "spawnWrite", "spawnEnd", "spawnKill", "spawnRef",
            "spawnMessage", "ipcSend", "ipcHold", "ipcDisconnect", "portDeliver",
        ) to
            "a child is either msh running a command or a second engine with live pipes; neither " +
            "is attached to the Android host, and `process.send` is correctly undefined without " +
            "the IPC channel that would make it real",
        listOf("unhandledRejection") to
            "iOS reports an unhandled promise rejection through JavaScriptCore's " +
            "`JSGlobalContextSetUnhandledRejectionCallback`. A WebView has a hook, but it is the " +
            "WRONG SHAPE, and the difference is the whole reason this is deferred rather than " +
            "wired. Measured on device, not reasoned about: the DOM `unhandledrejection` event " +
            "is present as API surface — `addEventListener` is a function, assigning " +
            "`onunhandledrejection` sticks — and it NEVER FIRES. Four rejection sites across " +
            "three programs, both registration styles, native V8 promises on the real window, " +
            "500 ms each, zero events. Chromium detects every one of them regardless and reports " +
            "it on the CONSOLE channel, where `WebChromeClient.onConsoleMessage` can read it: " +
            "`\"Uncaught (in promise) Error: boom\", source: mouse:///rej.js (11)`. That channel " +
            "carries a formatted STRING. node hands a handler the `reason` VALUE and the " +
            "`promise`, and the bootstrap's `__mouseOnUnhandledRejection` is written to that " +
            "signature, so the console text serves the no-handler half of node's contract and " +
            "cannot serve `process.on('unhandledRejection')` without fabricating a reason the " +
            "program would then branch on. THE FATAL HALF IS WIRED, out of band, in " +
            "`NodeWebView.onUnhandledRejection`: no listener prints and exits 1, a listener does " +
            "not exit, and the listener itself is never called. This name stays deferred because " +
            "the ENGINE path really is unwired — the bootstrap still cannot reach a host here",
    )

    /**
     * Flatten the surface groups, refusing a name that appears in two of them — a duplicate would
     * silently give one surface's reason to another's method.
     */
    private fun buildDeferred(vararg groups: Pair<List<String>, String>): Map<String, String> {
        val out = LinkedHashMap<String, String>()
        for ((names, reason) in groups) {
            for (name in names) {
                require(out.put(name, reason) == null) { "$name is deferred twice" }
            }
        }
        return out
    }

    private val BRIDGE_REFERENCE = Regex("""\bbridge\.([A-Za-z_][A-Za-z0-9_]*)""")

    /** Every `bridge.<name>` the bootstrap actually touches. */
    fun referencedNames(bootstrapJs: String): Set<String> =
        BRIDGE_REFERENCE.findAll(bootstrapJs).map { it.groupValues[1] }.toSortedSet()

    /**
     * The JS that stubs out [DEFERRED]. Generated rather than written into the shim asset so the
     * list has exactly one home — the one `:nodecheck` grades.
     *
     * The wording matters. AGENTS.md: a refusal must NAME A REASON and stay true, and must not
     * read as a stale "not available yet" — so it names the thing that is missing (a host binding
     * on this platform) rather than promising one.
     */
    fun deferredStubScript(): String {
        // The reasons are shared by whole surfaces, so they cross once each and the names carry an
        // index into them. Twenty-nine copies of the socket sentence would be the same text five
        // times over, and a reader diffing this script would have to compare all of them.
        val reasons = DEFERRED.values.distinct()
        val index = reasons.withIndex().associate { (at, reason) -> reason to at }
        val reasonLiterals = reasons.joinToString(",") { jsString(it) }
        val nameLiterals = DEFERRED.entries.joinToString(",") { (name, reason) ->
            jsString(name) + ":" + index[reason]
        }
        return """
            (function(){
              var reasons = [$reasonLiterals];
              var missing = {$nameLiterals};
              Object.keys(missing).forEach(function(name){
                var reason = reasons[missing[name]];
                globalThis.__mouse[name] = function() {
                  var error = new Error('__mouse.' + name + ' has no Android host binding — ' + reason);
                  error.code = 'ERR_MOUSE_NO_HOST_BINDING';
                  throw error;
                };
              });
            })();
        """.trimIndent()
    }

    /**
     * The exact call the host evaluates when a timer comes due. Kept here, next to the protocol it
     * belongs to, so the pure module owns the framing and the Android host owns only the delivery.
     */
    fun dispatchTimer(id: Int): String = "globalThis.__mouseDispatch.timer($id);"

    /** The same for the immediate queue. The host drains a batch, matching the iOS loop. */
    fun dispatchImmediate(ids: List<Int>): String =
        "globalThis.__mouseDispatch.immediates([${ids.joinToString(",")}]);"

    /**
     * One I/O completion, ready to be queued as a JOB.
     *
     * A job is the iOS `enqueueJob` — the queue the event loop drains FIRST, ahead of immediates
     * and timers, and the route every socket event, DNS answer and HTTP chunk takes back into
     * JavaScript. The shape is the same trick timers use, for the same reason: a function cannot
     * cross `@JavascriptInterface`, so the callback stays in a JS registry and only its id and its
     * ARGUMENTS travel.
     *
     * [argsJson] is a JSON array applied to the callback, so the bootstrap sees exactly the
     * argument list the iOS block passes. [final] says the registry entry may be dropped
     * afterwards — true for a one-shot (a DNS answer, an HTTP body) and for a socket's own
     * `close`, false for every event of a socket that is still alive. Without it the registry
     * grows one entry per connection for the life of the program.
     */
    fun job(handlerId: Int, argsJson: String, final: Boolean): String =
        "[$handlerId,${jsString(argsJson)},${if (final) 1 else 0}]"

    /** A whole batch of [job] entries, run as one turn — the shape the iOS loop drains jobs in. */
    fun dispatchJobs(jobs: List<String>): String =
        "globalThis.__mouseDispatch.jobs([${jobs.joinToString(",")}]);"

    /**
     * A JavaScript string literal for [value].
     *
     * U+2028 and U+2029 are line terminators to a JS parser but to nothing else, and `<` is
     * escaped because these literals are also evaluated inside a `loadDataWithBaseURL` document.
     */
    fun jsString(value: String): String {
        val out = StringBuilder(value.length + 2)
        out.append('"')
        for (c in value) {
            val code = c.code
            when {
                c == '"' -> out.append("\\\"")
                c == '\\' -> out.append("\\\\")
                c == '\n' -> out.append("\\n")
                c == '\r' -> out.append("\\r")
                c == '\t' -> out.append("\\t")
                c == '<' -> out.append("\\u003c")
                code < 0x20 || code == 0x7f || code == 0x2028 || code == 0x2029 ->
                    out.append("\\u").append(String.format("%04x", code))
                else -> out.append(c)
            }
        }
        out.append('"')
        return out.toString()
    }
}
