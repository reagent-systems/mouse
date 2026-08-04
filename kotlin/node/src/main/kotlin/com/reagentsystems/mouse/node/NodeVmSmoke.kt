package com.reagentsystems.mouse.node

/**
 * `vm` — a second JavaScript context, and the first program in this suite that is DEVICE-ONLY.
 *
 * Every other shared program runs twice: under real `node` in `:nodecheck` against a JavaScript
 * stand-in host, and on the device through the real WebView. This one cannot. The second context
 * is an `about:blank` iframe, so it needs a DOM, and real node has none — `vm.createContext` would
 * refuse there for a reason that has nothing to do with the code under test.
 *
 * So it is run only by `NodeCheckReceiver`, and that is stated here rather than left for someone
 * to infer from its absence. The alternative — asserting one thing of a host with a DOM and
 * another of a host without one — is the trap the ES module refusal fell into, where a shared
 * program expected a refusal on one side and a result on the other.
 *
 * What it checks is the part of `vm` that is actually load-bearing: that the context is SEPARATE
 * (its globals and intrinsics are its own), that the sandbox crosses in both directions, and that
 * a throw inside the guest reaches the caller's frame instead of vanishing.
 */
object NodeVmSmoke {

    val CONFIG: NodeProcessConfig = NodeProcessConfig(
        argv = listOf("/usr/local/bin/node", "/vm.js"),
        cwd = "/",
    )

    const val ENTRY_PATH: String = "/vm.js"

    private const val EXIT_CODE = 11

    val PROGRAM: String = """
        const vm = require('vm');
        const out = [];
        const say = (key, value) => out.push(key + '=' + value);

        // A sandbox goes IN as globals and comes back OUT with whatever the guest left on it.
        const sandbox = { seed: 40 };
        vm.createContext(sandbox);
        vm.runInContext('total = seed + 2; añadido = "unicode-name-ok";', sandbox);
        say('total', sandbox.total);
        say('added', sandbox['añadido']);

        // Separate globals: what the guest declares must not leak out here.
        vm.runInContext('globalThis.leaked = "no"', sandbox);
        say('leak', typeof globalThis.leaked);

        // Separate INTRINSICS — the property that makes it a context rather than a scope. An
        // array built in there is not an instance of the Array out here, which is exactly why
        // node documents `vm` as unsuitable for sandboxing untrusted code by itself.
        const theirs = vm.runInContext('[1, 2, 3]', sandbox);
        say('length', theirs.length);
        say('foreign', theirs instanceof Array);

        // A throw inside the guest belongs in the caller's frame.
        let thrown = 'none';
        try { vm.runInContext('throw new Error("from inside")', sandbox); }
        catch (e) { thrown = e && e.message; }
        say('threw', thrown);

        // Two contexts must not see each other.
        const a = { tag: 'a' }, b = { tag: 'b' };
        vm.createContext(a); vm.createContext(b);
        vm.runInContext('mine = tag + "-only"', a);
        vm.runInContext('mine = tag + "-only"', b);
        say('two', a.mine + ',' + b.mine);

        console.log(out.join('\n'));
        process.exit($EXIT_CODE);
    """.trimIndent()

    /** key → (expected, what the check is called). Same shape as the other smokes' graders. */
    private val EXPECTED: List<Triple<String, String, String>> = listOf(
        Triple("total", "42", "a sandbox's values arrive as globals in the context"),
        Triple("added", "unicode-name-ok", "and a name the guest invented comes back out"),
        Triple("leak", "undefined", "what the guest declares does not leak into this context"),
        Triple("length", "3", "a value built in the context crosses back usably"),
        Triple("foreign", "false", "the context's intrinsics are its own — its Array is not ours"),
        Triple("threw", "from inside", "a throw inside the guest reaches the caller's frame"),
        Triple("two", "a-only,b-only", "two contexts do not see each other"),
    )

    val CHECK_COUNT: Int = EXPECTED.size + 1

    /** Grade a run: the transcript's `key=value` lines, plus the exit code. */
    fun grade(stdout: String, stderr: String, exit: Int): List<String> {
        val seen = HashMap<String, String>()
        for (line in stdout.lines()) {
            val at = line.indexOf('=')
            if (at > 0) seen[line.substring(0, at)] = line.substring(at + 1)
        }
        val failures = ArrayList<String>()
        for ((key, expected, label) in EXPECTED) {
            val got = seen[key] ?: "<absent>"
            if (got != expected) failures.add("$label — $key was $got, expected $expected")
        }
        if (exit != EXIT_CODE) {
            failures.add("the program ran to its end — exit was $exit, expected $EXIT_CODE")
        }
        if (stderr.isNotBlank()) failures.add("nothing was written to stderr — got: ${stderr.take(300)}")
        return failures
    }
}
