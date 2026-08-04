package com.reagentsystems.mouse.node

/**
 * Milestone 3b's program: the filesystem, and `require` over `node_modules`.
 *
 * Same discipline as [NodeSmoke] — one source, one grader, run by `:nodecheck` under real `node`
 * against a JavaScript stand-in for the host, and by `NodeCheckReceiver` on a device through the
 * real WebView. If the two gates graded different programs, an on-device MISMATCH would never say
 * whether the WebView was wrong or the corpus was.
 *
 * ## The program builds its own tree
 *
 * Every fixture this needs — packages, a scoped package with an "exports" map, a circular pair, a
 * module that throws — is written by the program itself through `fs`, and only then required. That
 * is deliberate twice over: it means neither host has to plant a tree before the run (the device
 * gate has no `verify/` directory to read), and it means the require half is exercised against
 * files the fs half just proved it can write. A tree the host planted would let a broken
 * `writeFile` pass unnoticed.
 *
 * ## Refusals are probed in BOTH directions
 *
 * AGENTS.md: "Gate the DOCUMENTATION, not just the code … probe each API the docs call absent and
 * fail if it works; probe the built ones too, so the claim cannot rot in either direction." So
 * every name in [HostBridge.DEFERRED] is called and must refuse with its code, and the ones this
 * milestone implemented are called and must answer. A capability that quietly starts working, or
 * quietly stops, fails here rather than being discovered by a package.
 */
object NodeFsSmoke {

    /** The process the program is run against, on both hosts. */
    val CONFIG: NodeProcessConfig = NodeProcessConfig(
        argv = listOf("/usr/local/bin/node", "/main.js"),
        env = mapOf("MOUSE_CHECK" to "1"),
        cwd = "/",
    )

    const val ENTRY_PATH: String = "/main.js"

    private const val EXIT_CODE = 7

    /**
     * Every deferred bridge name, as a JavaScript array literal. Generated rather than written
     * out, so a name that moves between the two halves of the partition is probed correctly
     * without anyone remembering to edit a second list.
     */
    private val deferredNames: String =
        HostBridge.DEFERRED.keys.joinToString(",") { HostBridge.jsString(it) }

    val PROGRAM: String = """
        const fs = require('fs');
        const path = require('path');
        const out = [];
        const say = (key, value) => out.push(key + '=' + value);
        const codeOf = (fn) => { try { fn(); return 'no-throw'; } catch (e) { return e.code || e.message; } };

        // ---------------------------------------------------------------- filesystem ----
        fs.mkdirSync('/work/pkg/lib', { recursive: true });
        fs.writeFileSync('/work/hello.txt', 'héllo\n');
        say('read', fs.readFileSync('/work/hello.txt', 'utf8').trim());
        // Bytes, not characters: 'h' + 2-byte 'é' + 'llo' + '\n'. A String hop that decoded as
        // anything but UTF-8 would answer 6 here and look almost right.
        say('bytes', fs.readFileSync('/work/hello.txt').length);
        fs.appendFileSync('/work/hello.txt', 'more\n');
        say('appended', fs.readFileSync('/work/hello.txt', 'utf8').trim().split('\n').length);

        // Binary. Content crosses the bridge as base64 on both platforms, and this is what says
        // so: every byte value there is, back unchanged.
        const bytes = Buffer.alloc(256);
        for (let i = 0; i < 256; i++) bytes[i] = i;
        fs.writeFileSync('/work/bytes.bin', bytes);
        const back = fs.readFileSync('/work/bytes.bin');
        say('binary', back.length === 256 && back[0] === 0 && back[128] === 128 && back[255] === 255);

        const stats = fs.statSync('/work/hello.txt');
        say('isfile', stats.isFile() + ',' + stats.isDirectory());
        say('size', stats.size);
        // `mode` is not cosmetic: chokidar gates every entry on `4 & parseInt(stats.mode, 10)`, so
        // a Stats without one reads as "not readable" and hides every file in a watched tree.
        say('modereadable', (4 & parseInt(stats.mode, 10)) !== 0);
        say('mtime', stats.mtimeMs > 0 && stats.mtime instanceof Date);

        fs.writeFileSync('/work/pkg/lib/z.txt', 'z');
        fs.writeFileSync('/work/pkg/lib/a.txt', 'a');
        say('readdir', fs.readdirSync('/work/pkg/lib').join(','));
        fs.renameSync('/work/pkg/lib/z.txt', '/work/pkg/lib/y.txt');
        say('renamed', fs.readdirSync('/work/pkg/lib').join(','));
        fs.unlinkSync('/work/pkg/lib/y.txt');
        say('unlinked', fs.existsSync('/work/pkg/lib/y.txt'));
        say('statfs', typeof fs.statfsSync('/').bsize === 'number' && fs.statfsSync('/').bsize > 0);

        // The strictness that lives in the shared bootstrap rather than in either host's
        // primitives. `verify/fsparity` grades the whole family; these three are here so that a
        // primitive which quietly succeeded where it should fail is caught by this gate too.
        say('missing', codeOf(() => fs.readFileSync('/work/nope.txt')));
        say('isdir', codeOf(() => fs.readFileSync('/work/pkg')));
        say('noparent', codeOf(() => fs.mkdirSync('/work/no/where')));

        // ------------------------------------------------------------------- require ----
        const write = (p, text) => { fs.mkdirSync(path.dirname(p), { recursive: true }); fs.writeFileSync(p, text); };
        write('/work/pkg/package.json', '{"name":"app","main":"index.js"}');
        write('/work/pkg/data.json', '{"answer":42}');
        // A circular pair: requiring `a` must give `b` the LIVE partial exports of `a`.
        write('/work/pkg/a.js', 'exports.name = "a"; exports.viaB = require("./b").name; exports.sawA = require("./b").sawA;');
        write('/work/pkg/b.js', 'exports.name = "b"; exports.sawA = require("./a").name;');
        write('/work/pkg/dir/index.js', 'module.exports = "from-index";');
        write('/work/pkg/boom.js', 'throw new Error("boom");');
        write('/work/pkg/node_modules/dep/package.json', '{"name":"dep","main":"lib/main.js"}');
        write('/work/pkg/node_modules/dep/lib/main.js', 'module.exports = { hello: () => "from-dep" };');
        write('/work/pkg/node_modules/@scope/thing/package.json',
              '{"name":"@scope/thing","exports":{".":"./main.js","./extra":"./extra.js"}}');
        write('/work/pkg/node_modules/@scope/thing/main.js', 'module.exports = "scoped-main";');
        write('/work/pkg/node_modules/@scope/thing/extra.js', 'module.exports = "scoped-extra";');
        write('/work/pkg/node_modules/@scope/thing/hidden.js', 'module.exports = "hidden";');
        write('/work/pkg/esm.mjs', 'export default 1;');
        // The module that does the requiring lives INSIDE the package, so the node_modules walk
        // starts where a real dependency's would. Requiring it from here would search "/".
        // A bare specifier is resolved from the requiring FILE's directory, so the failing cases
        // have to be asked from inside the package too — asked from the entry at "/" they would
        // all be MODULE_NOT_FOUND and the "exports" refusal would never be reached.
        write('/work/pkg/index.js', [
          'const code = (fn) => { try { fn(); return "no-throw"; } catch (e) { return e.code || e.message; } };',
          'module.exports = {',
          '  dep: require("dep").hello(),',
          '  scoped: require("@scope/thing"),',
          '  extra: require("@scope/thing/extra"),',
          '  core: typeof require("path").join,',
          '  resolved: require.resolve("dep"),',
          '  paths: require.resolve.paths("dep").length > 0,',
          '  same: require("./a") === require("./a"),',
          '  notExported: () => code(() => require("@scope/thing/hidden")),',
          '  notFound: () => code(() => require("no-such-package")),',
          '};',
        ].join('\n'));

        const app = require('/work/pkg/index.js');
        say('dep', app.dep);
        say('scoped', app.scoped + ',' + app.extra);
        say('core', app.core);
        say('resolved', app.resolved);
        say('paths', app.paths);
        say('cached', app.same);
        say('json', require('/work/pkg/data.json').answer);
        say('index', require('/work/pkg/dir'));
        // Extension probing: no suffix asked for, `.js` found.
        say('circular', require('/work/pkg/a').viaB + ',' + require('/work/pkg/a').sawA);
        say('notexported', app.notExported());
        say('notfound', app.notFound());
        say('esm', codeOf(() => require('/work/pkg/esm.mjs')));
        // A module that throws must not linger as partial exports: the SECOND require must run it
        // again and throw the same thing, not hand back a half-built object.
        say('threw', codeOf(() => require('/work/pkg/boom')) + ',' + codeOf(() => require('/work/pkg/boom')));

        // -------------------------------------------------------------- the refusals ----
        // Both directions. A deferred name that answers is as much a failure as an implemented
        // one that refuses — the first means the record is stale, the second means a regression.
        const deferred = [$deferredNames];
        let refused = 0;
        let wrong = [];
        for (const name of deferred) {
          const fn = globalThis.__mouse[name];
          if (typeof fn !== 'function') { wrong.push(name + ':absent'); continue; }
          try { fn(); wrong.push(name + ':answered'); }
          catch (e) { if (e.code === 'ERR_MOUSE_NO_HOST_BINDING') refused += 1; else wrong.push(name + ':' + e.code); }
        }
        say('refused', refused === deferred.length ? deferred.length : 'wrong[' + wrong.join(' ') + ']');
        const built = codeOf(() => {
          if (!globalThis.__mouse.stat('/', true).dir) throw new Error('stat');
          if (!Array.isArray(globalThis.__mouse.readdir('/'))) throw new Error('readdir');
          const cpu = globalThis.__mouse.cpuUsage();
          if (typeof cpu.user !== 'number' || typeof cpu.system !== 'number') throw new Error('cpuUsage');
          const loop = globalThis.__mouse.loopUtilization();
          if (typeof loop.idle !== 'number' || typeof loop.active !== 'number') throw new Error('loopUtilization');
          globalThis.__mouse.setRawMode(false);
        });
        say('built', built);

        console.log(out.join('\n'));
        process.exit($EXIT_CODE);
    """.trimIndent()

    private val EXPECTED: List<Triple<String, String, String>> = listOf(
        Triple("read", "héllo", "writeFileSync then readFileSync round-trips text"),
        Triple("bytes", "7", "content crosses as BYTES — 'é' is two of them, not one"),
        Triple("appended", "2", "appendFileSync appends rather than truncating"),
        Triple("binary", "true", "all 256 byte values survive the base64 hop"),
        Triple("isfile", "true,false", "Stats knows a file from a directory"),
        Triple("size", "12", "Stats.size is the file's real length"),
        Triple("modereadable", "true", "Stats.mode is a real mode — the chokidar bug"),
        Triple("mtime", "true", "Stats carries both the Ms and the Date forms"),
        Triple("readdir", "a.txt,z.txt", "readdirSync lists, sorted"),
        Triple("renamed", "a.txt,y.txt", "renameSync moves"),
        Triple("unlinked", "false", "unlinkSync removes"),
        Triple("statfs", "true", "statfs reports a real block size"),
        Triple("missing", "ENOENT", "reading a missing file is ENOENT"),
        Triple("isdir", "EISDIR", "reading a directory is EISDIR"),
        Triple("noparent", "ENOENT", "mkdir without a parent is ENOENT, not a silent mkdir -p"),
        Triple("dep", "from-dep", "a bare specifier resolves through node_modules and package.json main"),
        Triple("scoped", "scoped-main,scoped-extra", "a scoped package's \"exports\" map, root and subpath"),
        Triple("core", "function", "a core module still comes from the bootstrap"),
        Triple("resolved", "/work/pkg/node_modules/dep/lib/main.js", "require.resolve answers the resolved id"),
        Triple("paths", "true", "require.resolve.paths lists the node_modules walk — jest needs it"),
        Triple("cached", "true", "one module object per file, however many times it is required"),
        Triple("json", "42", "a .json file requires as parsed data"),
        Triple("index", "from-index", "a directory falls back to index.js"),
        Triple("circular", "b,a", "a circular require reads the partner's LIVE partial exports"),
        Triple("notexported", "ERR_PACKAGE_PATH_NOT_EXPORTED", "a subpath outside \"exports\" is refused, with its own code"),
        Triple("notfound", "MODULE_NOT_FOUND", "a missing package is MODULE_NOT_FOUND"),
        Triple("esm", "ERR_REQUIRE_ESM", "require() of an ES module refuses by name — no transpiler on Android"),
        Triple("threw", "boom,boom", "a module that throws is evicted, so the next require runs it again"),
        Triple("refused", HostBridge.DEFERRED.size.toString(), "every deferred bridge name refuses with its code"),
        Triple("built", "no-throw", "every bridge name this milestone implemented answers"),
    )

    /** How many checks [grade] performs. Reported in the verdict line. */
    val CHECK_COUNT: Int = EXPECTED.size + 1

    /** Grade a run. Returns one line per failing check; empty means MATCH. */
    fun grade(stdout: String, stderr: String, exitCode: Int): List<String> {
        val failures = ArrayList<String>()
        val values = stdout.lineSequence().filter { it.contains('=') }
            .associate { it.substringBefore('=') to it.substringAfter('=') }
        for ((key, want, label) in EXPECTED) {
            val got = values[key]
            if (got != want) failures.add("$label — $key was ${got ?: "<absent>"}, expected $want")
        }
        if (exitCode != EXIT_CODE) {
            failures.add(
                "the program ran to its end — exit was $exitCode, expected $EXIT_CODE" +
                    if (stderr.isBlank()) "" else " (stderr: ${stderr.take(400)})",
            )
        }
        return failures
    }
}
