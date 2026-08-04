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
     * What milestone 3a binds for real. Everything a program needs to print, to be told who it is,
     * and to schedule work — plus the three the bootstrap calls before it has finished loading
     * (`monotonicNanos`, `createRequire`) or that hold the event loop open (`loopHold`,
     * `stdinActive`), which are loop machinery rather than a feature.
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
        // Also called at top level (`globalThis.__mouseRequire`). It must RETURN a function; the
        // function it returns is what refuses, because module loading is 3b.
        "createRequire",
        // Event-loop bookkeeping: an open handle and a live stdin listener each keep the loop
        // running. Both are no-ops with nothing to hold in 3a, but they are the loop's own
        // vocabulary and wiring them now is cheaper than discovering the omission later.
        "loopHold",
        "stdinActive",
    )

    /**
     * The rest of the iOS bridge, by the milestone that lands it. These exist as functions that
     * throw a NAMED refusal: a missing member reads as `undefined is not a function` from inside
     * the bootstrap with no clue attached, and a silent no-op is worse still (AGENTS.md: "a silent
     * no-op is a lie").
     */
    val DEFERRED: Set<String> = linkedSetOf(
        // 3b — the filesystem, module loading and the process surface that reads them
        "stat",
        "statfs",
        "readFile",
        "writeFile",
        "readdir",
        "mkdir",
        "remove",
        "rename",
        "chmodPath",
        "fsWatch",
        "fsUnwatch",
        "rewriteImports",
        "setRawMode",
        "cpuUsage",
        "loopUtilization",
        // 3c — sockets, DNS, HTTP, WebSocket, datagram
        "netConnect",
        "netConnectUnix",
        "netListen",
        "netListenUnix",
        "netListenHandoff",
        "netAdopt",
        "netWrite",
        "netEnd",
        "netDestroy",
        "netDiscard",
        "netPause",
        "netResume",
        "netRef",
        "netNoDelay",
        "netKeepAlive",
        "netResolve",
        "dnsResolve",
        "dnsReverse",
        "dnsService",
        "dnsDone",
        "httpRequest",
        "httpStream",
        "wsOpen",
        "wsSend",
        "wsClose",
        "dgramBind",
        "dgramSend",
        "dgramOption",
        "dgramMembership",
        // 3d — crypto, compression, vm, child processes, workers
        "cryptoHash",
        "cryptoHmac",
        "randomBytes",
        "randomUUID",
        "pbkdf2",
        "scrypt",
        "hkdf",
        "cipherOpen",
        "cipherSeal",
        "keyGenerate",
        "keyIdentify",
        "keySign",
        "keyVerify",
        "keyAgree",
        "ecdhGenerate",
        "ecdhCompute",
        "rsaGenerate",
        "rsaSign",
        "rsaVerify",
        "rsaEncrypt",
        "rsaDecrypt",
        "rsaPrivateEncrypt",
        "rsaPublicDecrypt",
        "zlibOpen",
        "zlibPush",
        "zlibClose",
        "zlibTransform",
        "brotliOpen",
        "brotliPush",
        "brotliClose",
        "brotliTransform",
        "vmCreate",
        "vmRun",
        "shellExec",
        "spawnNode",
        "spawnWrite",
        "spawnEnd",
        "spawnKill",
        "spawnRef",
        "spawnMessage",
        "ipcSend",
        "ipcHold",
        "ipcDisconnect",
        "portDeliver",
        "unhandledRejection",
    )

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
        val names = DEFERRED.joinToString(",") { jsString(it) }
        return """
            (function(){
              var missing = [$names];
              for (var i = 0; i < missing.length; i++) {
                (function(name){
                  globalThis.__mouse[name] = function() {
                    var error = new Error('__mouse.' + name + ' has no Android host binding: the '
                      + 'WebView host implements the console/process/timer bridge, and this call '
                      + 'belongs to a surface (fs, modules, sockets, crypto, children) that is not '
                      + 'wired to it');
                    error.code = 'ERR_MOUSE_NO_HOST_BINDING';
                    throw error;
                  };
                })(missing[i]);
              }
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
