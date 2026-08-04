package com.reagentsystems.mouse.node

/**
 * One program, and the grading of it, shared by both hosts that can run this layer.
 *
 * `:nodecheck` runs it under real `node` with a JavaScript stand-in for `__mouseHost`;
 * `NodeCheckReceiver` runs it on a device through the real WebView. Same source, same
 * expectations, same failure text — which is the point. If the two gates graded different
 * programs, an on-device MISMATCH would never tell you whether the WebView was wrong or the
 * program was, and the JVM half could not prove the device half can fail.
 *
 * Everything the program reports travels out through `console.log`, deliberately: a passing run
 * is itself the proof that console reaches the host, because there is no side channel.
 */
object NodeSmoke {

    /**
     * The program. It must be the FIRST thing the engine runs in its host: `__leaveEntryFrame`
     * flips `hostFrame` false for good afterwards, and which side of a microtask checkpoint a
     * `nextTick` was called from is exactly what decides when it runs. Only the first entry is a
     * main module.
     */
    val PROGRAM: String = """
        const seen = [];
        process.nextTick(function(){ seen.push('tick'); });
        Promise.resolve().then(function(){ seen.push('promise'); });
        setImmediate(function(){ seen.push('immediate'); });

        const doomed = setTimeout(function(){ console.log('cancelled-timer-ran=yes'); }, 1);
        clearTimeout(doomed);

        let ticks = 0;
        const every = setInterval(function(){ if (++ticks === 3) clearInterval(every); }, 2);

        // `__mouseRequire` is what `bridge.createRequire('/')` handed back while the bootstrap
        // loaded — the referrer for source compiled at runtime, which has no other way to name
        // one. Since 3b it is a real loader, so a core module comes back rather than a refusal.
        let requireCode = 'no-throw';
        try { requireCode = typeof globalThis.__mouseRequire('fs').readFileSync; }
        catch (e) { requireCode = e.code || e.message; }
        // A surface with no Android host binding must still refuse BY NAME. `cryptoHash` is one of
        // the generated stubs; `NodeFsSmoke` probes the whole list, both directions.
        //
        // This used to probe `netConnect`, and 3c is what made that wrong: the moment sockets were
        // real, a check asserting they refuse became a check asserting a regression. That is the
        // partition doing its job — it went red and named the line, rather than the capability
        // quietly disagreeing with the record.
        let refusal = 'no-throw';
        try { globalThis.__mouse.cryptoHash('sha256', ''); }
        catch (e) { refusal = e.code || e.message; }

        setTimeout(function(){
          seen.push('timeout');
          console.log('sum=' + (1 + 1));
          console.log('order=' + seen.join(','));
          console.log('interval=' + ticks);
          console.log('version=' + process.version);
          console.log('argv=' + process.argv.join(','));
          console.log('env=' + process.env.MOUSE_CHECK);
          console.log('cwd=' + process.cwd());
          console.log('require=' + requireCode);
          console.log('refusal=' + refusal);
          console.error('stderr-reached');
          process.exit(5);
        }, 20);
    """.trimIndent()

    /** The process the program is run against, on both hosts. */
    val CONFIG: NodeProcessConfig = NodeProcessConfig(
        argv = listOf("/usr/local/bin/node", "/nodecheck.js", "alpha"),
        env = mapOf("MOUSE_CHECK" to "1"),
        cwd = "/",
    )

    const val ENTRY_PATH: String = "/nodecheck.js"

    private const val EXIT_CODE = 5

    private val EXPECTED: List<Triple<String, String, String>> = listOf(
        Triple("sum", "2", "console.log(1 + 1) reaches the host"),
        // The ordering the iOS side paid for, and the whole reason `__invoke` and the leading
        // drain in node-host.js exist: the WHOLE nextTick queue drains before ANY promise
        // reaction, both run before an immediate, and timers come last.
        Triple("order", "tick,promise,immediate,timeout", "nextTick, then microtasks, then immediates, then timers"),
        Triple("interval", "3", "setInterval repeats until cleared"),
        Triple("version", "v22.22.3", "process.version is the engine's"),
        Triple("argv", "/usr/local/bin/node,/nodecheck.js,alpha", "process.argv is the host's"),
        Triple("env", "1", "process.env is the host's"),
        Triple("cwd", "/", "process.cwd() is the host's"),
        Triple("require", "function", "the bootstrap's own require reaches a core module"),
        Triple("refusal", "ERR_MOUSE_NO_HOST_BINDING", "a deferred bridge surface refuses with its code"),
    )

    /** How many checks [grade] performs. Reported in the verdict line. */
    val CHECK_COUNT: Int = EXPECTED.size + 3

    /** Grade a run. Returns one line per failing check; empty means MATCH. */
    fun grade(stdout: String, stderr: String, exitCode: Int): List<String> {
        val failures = ArrayList<String>()
        val values = stdout.lineSequence().filter { it.contains('=') }
            .associate { it.substringBefore('=') to it.substringAfter('=') }
        for ((key, want, label) in EXPECTED) {
            val got = values[key]
            if (got != want) failures.add("$label — $key was ${got ?: "<absent>"}, expected $want")
        }
        if (!stderr.contains("stderr-reached")) {
            failures.add("console.error reaches the host on stderr — stderr was ${stderr.take(200)}")
        }
        if (values.containsKey("cancelled-timer-ran")) {
            failures.add("clearTimeout cancels a pending timer — the cancelled timer ran")
        }
        if (exitCode != EXIT_CODE) {
            failures.add("process.exit carries its code to the host — exit was $exitCode, expected $EXIT_CODE")
        }
        return failures
    }
}
