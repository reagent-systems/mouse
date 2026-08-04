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
            "framework, so it cannot live in the pure module this bridge is partitioned in — plus " +
            "a way for the host to call BACK into JavaScript with each event, which is the same " +
            "machinery the socket layer needs and does not exist yet",
        listOf("rewriteImports") to
            "this rewrites `import(…)` inside source compiled at RUNTIME, and it is one entry " +
            "point to the ES module transpiler; Android has no transpiler, which is also why " +
            "`require()` of an ES module refuses with ERR_REQUIRE_ESM rather than loading it",
        listOf(
            "netConnect", "netConnectUnix", "netListen", "netListenUnix", "netListenHandoff",
            "netAdopt", "netWrite", "netEnd", "netDestroy", "netDiscard", "netPause", "netResume",
            "netRef", "netNoDelay", "netKeepAlive", "netResolve", "dnsResolve", "dnsReverse",
            "dnsService", "dnsDone", "httpRequest", "httpStream", "wsOpen", "wsSend", "wsClose",
            "dgramBind", "dgramSend", "dgramOption", "dgramMembership",
        ) to
            "net, http, dns, WebSocket and datagram all ride one socket layer, and Android has " +
            "none: `NodeSockets.swift` is a Dispatch-source engine with no Java NIO counterpart " +
            "written yet",
        listOf(
            "cryptoHash", "cryptoHmac", "randomBytes", "randomUUID", "pbkdf2", "scrypt", "hkdf",
            "cipherOpen", "cipherSeal", "keyGenerate", "keyIdentify", "keySign", "keyVerify",
            "keyAgree", "ecdhGenerate", "ecdhCompute", "rsaGenerate", "rsaSign", "rsaVerify",
            "rsaEncrypt", "rsaDecrypt", "rsaPrivateEncrypt", "rsaPublicDecrypt",
        ) to
            "the crypto surface rides CryptoKit, CommonCrypto and Security framework on iOS, and " +
            "nothing on Android is bound to its JCA counterparts yet",
        listOf(
            "zlibOpen", "zlibPush", "zlibClose", "zlibTransform",
            "brotliOpen", "brotliPush", "brotliClose", "brotliTransform",
        ) to
            "zlib rides libz and brotli rides Apple's Compression framework; the Android host " +
            "binds neither, and `java.util.zip` covers only half of what these carry",
        listOf("vmCreate", "vmRun") to
            "node's contextified sandbox is a SECOND JavaScript context sharing one virtual " +
            "machine, and a WebView gives no way to make another context reachable from this one",
        listOf(
            "shellExec", "spawnNode", "spawnWrite", "spawnEnd", "spawnKill", "spawnRef",
            "spawnMessage", "ipcSend", "ipcHold", "ipcDisconnect", "portDeliver",
        ) to
            "a child is either msh running a command or a second engine with live pipes; neither " +
            "is attached to the Android host, and `process.send` is correctly undefined without " +
            "the IPC channel that would make it real",
        listOf("unhandledRejection") to
            "iOS reports an unhandled promise rejection through JavaScriptCore's " +
            "`JSGlobalContextSetUnhandledRejectionCallback`; a WebView exposes no equivalent hook, " +
            "so nothing can call this",
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
