package com.reagentsystems.mouse.nodecheck

import com.reagentsystems.mouse.node.Bootstrap
import com.reagentsystems.mouse.node.HostBridge
import com.reagentsystems.mouse.node.ModuleResolver
import com.reagentsystems.mouse.node.NodeCpu
import com.reagentsystems.mouse.node.NodeFs
import com.reagentsystems.mouse.node.NodeFsSmoke
import com.reagentsystems.mouse.node.NodeLoop
import com.reagentsystems.mouse.node.NodeProcessConfig
import com.reagentsystems.mouse.node.NodeSmoke
import java.io.File
import java.nio.file.Files
import java.util.Base64
import java.util.concurrent.TimeUnit
import kotlin.system.exitProcess

// Headless verification of the Android Node layer's portable half (`:node`).
//
// The load-bearing check is DRIFT. The JS bootstrap in `kotlin/app/src/main/assets/` is a copy of
// a Swift raw-string literal in `swift/Mouse/NodeEngine.swift`, and a copy that diverges silently
// is worse than no copy at all — it is 14,000 lines of engine that LOOKS like the gated one. So
// the copy is never trusted: it is re-extracted from the shipping Swift file on every run and
// diffed. Same trick as `:screencheck` reading `verify/` fixtures rather than copying them.
//
// The transform is explicit and part of the comparison: `Bootstrap.extract` implements Swift's
// own multiline-literal indentation stripping and refuses on any `\#` escape, because a raw
// literal with `\#` in it is no longer verbatim. `--sync` rewrites the asset with the SAME code
// that grades it, so the transform cannot be right in one direction and wrong in the other.
//
// What else is gated here, all of it reachable without an emulator:
//
//   * the bridge partition — every `bridge.<name>` the shipping bootstrap calls is either
//     implemented by the Android host or explicitly deferred, exactly once. When the iOS engine
//     grows a bridge method this goes red and names it, instead of the WebView throwing
//     `undefined is not a function` from inside someone else's 14,000 lines.
//   * the process globals the bootstrap reads WHILE IT LOADS (`__argv`, `__env`, `__cwd`, …) —
//     checked against the preamble AND against the bootstrap text.
//   * the event loop's bookkeeping (`NodeLoop`): immediate batching, repeat re-arming, and the
//     quiescence rule that lets an unref'd watchdog exit.
//   * `node --check` on the extracted bootstrap. AGENTS.md: "Run `node --check` on the extracted
//     bootstrap after every edit" — `interface` as a parameter name compiles fine on the Swift
//     side and breaks the engine, because swiftc cannot see into the string.
//   * a LOAD SMOKE under real `node`: the shim, the stubs, the globals and the bootstrap are
//     evaluated in order against a JS stand-in for `__mouseHost`, and console/process/timers are
//     exercised through the real protocol. This is not the WebView — the WebView is gated on
//     device by `NodeCheckReceiver` — but it is the same four scripts in the same order, so a
//     load-order or protocol mistake fails here rather than on a phone.
//
// No JUnit, by invariant #4: this is a main() that prints one verdict line and exits non-zero,
// the same shape as `:screencheck`, `:pkgcheck` and the Swift harnesses in verify/.

private var failures = 0
private var checks = 0

private fun check(condition: Boolean, label: String) {
    checks += 1
    if (!condition) {
        failures += 1
        println("  FAIL: $label")
    }
}

private fun checkEqual(got: String, want: String, label: String) {
    checks += 1
    if (got != want) {
        failures += 1
        println("  FAIL: $label\n    got:  ${got.take(200)}\n    want: ${want.take(200)}")
    }
}

private val repoRoot: File by lazy {
    val declared = System.getProperty("mouse.repo.root")
    if (declared != null) return@lazy File(declared)
    // Walk up from the working directory so the harness still finds the sources when it is
    // started by hand rather than through the `run` task.
    var candidate: File? = File(".").absoluteFile
    while (candidate != null) {
        if (File(candidate, Bootstrap.SWIFT_PATH).exists()) return@lazy candidate
        candidate = candidate.parentFile
    }
    File(".").absoluteFile
}

private val swiftFile: File get() = File(repoRoot, Bootstrap.SWIFT_PATH)
private val assetFile: File get() = File(repoRoot, Bootstrap.ASSET_PATH)
private val shimFile: File get() = File(repoRoot, HostBridge.SHIM_ASSET_PATH)

// ------------------------------------------------------------------------- drift ----------

private fun driftCorpus(): String {
    check(swiftFile.exists(), "${Bootstrap.SWIFT_PATH} exists")
    check(assetFile.exists(), "${Bootstrap.ASSET_PATH} exists")
    if (!swiftFile.exists() || !assetFile.exists()) return ""

    val extracted = try {
        Bootstrap.extract(swiftFile.readText())
    } catch (failure: Bootstrap.ExtractionFailure) {
        failures += 1
        checks += 1
        println("  FAIL: extracting the bootstrap from ${Bootstrap.SWIFT_PATH}: ${failure.message}")
        return ""
    }
    checks += 1
    check(extracted.length > 400_000, "the extracted bootstrap is the whole engine, not a fragment")

    val asset = assetFile.readText()
    val difference = Bootstrap.firstDifference(extracted, asset)
    checks += 1
    if (difference != null) {
        failures += 1
        println(
            "  FAIL: ${Bootstrap.ASSET_PATH} has drifted from ${Bootstrap.SWIFT_PATH}\n" +
                "    first difference at $difference\n" +
                "    regenerate with: ./gradlew :nodecheck:run --args=--sync",
        )
    }
    return extracted
}

// ------------------------------------------------------------------------ bridge ----------

private fun bridgeCorpus(bootstrap: String) {
    if (bootstrap.isEmpty()) return
    val referenced = HostBridge.referencedNames(bootstrap)
    check(referenced.size > 80, "the bootstrap's bridge surface was found (${referenced.size} names)")

    val accounted = HostBridge.IMPLEMENTED + HostBridge.DEFERRED.keys
    val unaccounted = referenced - accounted
    check(
        unaccounted.isEmpty(),
        "every bridge name the bootstrap calls is implemented or deferred " +
            "(unaccounted: ${unaccounted.sorted()})",
    )
    val phantom = accounted - referenced
    check(
        phantom.isEmpty(),
        "no bridge name is listed that the bootstrap never calls (phantom: ${phantom.sorted()})",
    )
    val overlap = HostBridge.IMPLEMENTED intersect HostBridge.DEFERRED.keys
    check(overlap.isEmpty(), "no bridge name is both implemented and deferred (both: $overlap)")

    // The two the bootstrap calls at its TOP LEVEL cannot be stubs: it would throw while loading,
    // and the whole engine would be gone with no error a user could act on.
    for (name in listOf("monotonicNanos", "createRequire")) {
        check(name in HostBridge.IMPLEMENTED, "`$name` is implemented (the bootstrap calls it at load)")
    }

    // The refusal wording is a contract (AGENTS.md), so it is graded rather than assumed: it must
    // name the missing thing and must not read as a stale "coming soon".
    val stubs = HostBridge.deferredStubScript()
    check(stubs.contains("ERR_MOUSE_NO_HOST_BINDING"), "deferred bridge calls throw a coded error")
    for (rot in listOf("not available yet", "on the roadmap", "coming soon", "not supported yet")) {
        check(!stubs.contains(rot), "the refusal does not use the stale phrase \"$rot\"")
    }

    // Every deferred name carries a REASON, and the reason must be a sentence about this platform
    // rather than a placeholder. A refusal with nothing behind it is the shape AGENTS.md calls
    // worse than a gap: it stops anyone looking again.
    val reasonless = HostBridge.DEFERRED.filterValues { it.length < 40 }.keys
    check(reasonless.isEmpty(), "every deferred name names a reason (too short: $reasonless)")
    for ((name, reason) in HostBridge.DEFERRED) {
        check(stubs.contains(HostBridge.jsString(reason)), "the stub for `$name` carries its reason")
    }
    // And the reason must still be TRUE. A surface that has since been built must not be named as
    // missing anywhere — the `cluster` claim that said "single process" long after live children
    // landed is the shape this catches.
    val built = listOf(
        "filesystem" to listOf("stat", "readFile", "writeFile"),
        "module loader" to listOf("createRequire"),
    )
    for ((claim, names) in built) {
        if (names.none { it in HostBridge.IMPLEMENTED }) continue
        val stale = HostBridge.DEFERRED.filterValues {
            it.contains("no $claim") || it.contains("$claim is not")
        }.keys
        check(stale.isEmpty(), "no refusal still calls the $claim missing (stale: $stale)")
    }

    // The shim must define every implemented name, or the bootstrap finds `undefined`.
    check(shimFile.exists(), "${HostBridge.SHIM_ASSET_PATH} exists")
    if (shimFile.exists()) {
        val shim = shimFile.readText()
        val missing = HostBridge.IMPLEMENTED.filter { !shim.contains("bridge.$it =") }
        check(missing.isEmpty(), "node-host.js defines every implemented bridge name (missing: $missing)")
    }
}

// ----------------------------------------------------------------------- globals ----------

private fun globalsCorpus(bootstrap: String) {
    if (bootstrap.isEmpty()) return
    val script = NodeProcessConfig(
        argv = listOf("/usr/local/bin/node", "/main.js", "a b"),
        env = mapOf("HOME" to "/", "QUOTE" to "he said \"hi\"\n"),
        cwd = "/work",
    ).globalsScript()

    for (name in NodeProcessConfig.REQUIRED_GLOBALS) {
        check(script.contains("globalThis.$name ="), "the preamble sets $name")
        // And the bootstrap really does read it — a preamble entry nothing consumes is dead
        // weight that will be believed by the next person to read it.
        check(bootstrap.contains(name), "the bootstrap reads $name")
    }

    // Quoting: argv and env carry arbitrary user text into a script.
    check(script.contains("""he said \"hi\"\n"""), "the preamble escapes quotes and newlines")

    // NAPI_RS_FORCE_WASI is what makes napi-rs take its WebAssembly branch. Android cannot exec a
    // downloaded .node any more than iOS can, so the default has to be set here too.
    check(
        NodeProcessConfig().effectiveEnv()["NAPI_RS_FORCE_WASI"] == "true",
        "NAPI_RS_FORCE_WASI defaults on (a downloaded .node cannot be exec'd on Android either)",
    )
    check(
        NodeProcessConfig(env = mapOf("NAPI_RS_FORCE_WASI" to "false"))
            .effectiveEnv()["NAPI_RS_FORCE_WASI"] == "false",
        "an explicit NAPI_RS_FORCE_WASI is not overridden",
    )

    // The unlock pass. A WebView's global object is a `Window` and some of what the bootstrap
    // installs is already an accessor there — `globalThis.crypto = {…}` throws in strict mode and
    // kills the engine at line 768 of 13,993. iOS never meets this: JSC's global owns almost
    // nothing. The list is derived from the bootstrap, so it cannot rot; these three are the ones
    // that are accessors on every browser global and they are checked by name.
    val assigned = Bootstrap.assignedGlobals(bootstrap)
    for (name in listOf("crypto", "performance", "navigator")) {
        check(name in assigned, "the unlock pass covers `$name` (an accessor on a Window)")
    }
    val unlock = Bootstrap.unlockGlobalsScript(bootstrap)
    check(unlock.contains("Object.defineProperty"), "the unlock pass redefines rather than assigns")
    check(
        unlock.contains("descriptor.writable === true") && unlock.contains("!descriptor.configurable"),
        "the unlock pass leaves writable data properties alone and does not swallow a non-configurable one",
    )
}

// -------------------------------------------------------------------------- loop ----------

private fun loopCorpus() {
    val now = 1_000_000_000L

    // Immediates come out as a BATCH. One scheduled by another belongs to the next turn, or
    // timers starve forever — the reason the iOS loop snapshots rather than iterating in place.
    val batching = NodeLoop()
    val first = batching.setImmediate()
    val second = batching.setImmediate()
    checkEqual(batching.takeImmediates().toString(), listOf(first, second).toString(), "immediates come out in order")
    val third = batching.setImmediate()
    checkEqual(batching.takeImmediates().toString(), listOf(third).toString(), "an immediate queued during a batch waits for the next turn")
    check(batching.takeImmediates().isEmpty(), "the immediate queue empties")

    // Timers: earliest first, one-shots consumed once, repeats re-armed from NOW.
    val timers = NodeLoop()
    val late = timers.setTimer(50, repeat = false, nowNanos = now)
    val soon = timers.setTimer(10, repeat = false, nowNanos = now)
    check(timers.claimDue(now) == null, "nothing is due before its delay")
    checkEqual(timers.claimDue(now + 20_000_000L)?.id.toString(), soon.toString(), "the earliest due timer fires first")
    check(timers.claimDue(now + 20_000_000L) == null, "a one-shot fires exactly once")
    checkEqual(timers.claimDue(now + 60_000_000L)?.id.toString(), late.toString(), "the later timer follows")

    val repeating = NodeLoop()
    val tick = repeating.setTimer(10, repeat = true, nowNanos = now)
    check(repeating.claimDue(now + 10_000_000L)?.id == tick, "an interval fires")
    // A callback that overran must not leave a backlog of instantly-due repeats behind it: the
    // re-arm is from NOW, which is what `Date().addingTimeInterval(interval)` does on iOS.
    check(repeating.claimDue(now + 15_000_000L) == null, "an interval re-arms from now, not from its old due time")
    check(repeating.claimDue(now + 25_000_000L)?.id == tick, "and fires again one interval later")

    // Quiescence — the rule that decides whether a program is finished.
    val life = NodeLoop()
    check(life.isQuiescent(), "an empty loop is finished")
    val watchdog = life.setTimer(1000, repeat = true, nowNanos = now)
    check(!life.isQuiescent(), "a ref'd timer keeps the loop alive")
    life.refTimer(watchdog, false)
    check(life.isQuiescent(), "an unref'd watchdog is not a reason to stay alive")
    check(life.nextWaitMillis(now) != null, "an unref'd timer still has a due time — it fires, it just does not hold")
    life.hold(true)
    check(!life.isQuiescent(), "an open handle keeps the loop alive")
    life.hold(false)
    check(life.isQuiescent(), "releasing the handle finishes it")
    life.stdinActive = true
    check(!life.isQuiescent(), "a live stdin listener keeps the loop alive")
    life.stdinActive = false
    life.setImmediate()
    check(!life.isQuiescent(), "a queued immediate is work, not quiet")

    // refresh() restarts the countdown, which is what node documents.
    val refreshing = NodeLoop()
    val id = refreshing.setTimer(10, repeat = false, nowNanos = now)
    refreshing.refreshTimer(id, now + 9_000_000L)
    check(refreshing.claimDue(now + 10_000_000L) == null, "refresh() pushes the due time out")
    check(refreshing.claimDue(now + 19_000_000L)?.id == id, "and it fires a full delay later")

    // exitCode is write-once: the FIRST exit wins, as it does in a process.
    val exiting = NodeLoop()
    exiting.exitCode = 3
    exiting.exitCode = 0
    checkEqual(exiting.exitCode.toString(), "3", "the first process.exit wins")

    // Utilization: the host measures, the loop only accumulates — and it accumulates the two
    // numbers separately, which is the whole content of `eventLoopUtilization()`.
    val busy = NodeLoop()
    busy.recordIdle(4_000_000L)
    busy.recordActive(1_000_000L)
    busy.recordIdle(-5L)   // a clock that went backwards is not negative idle time
    val (idle, active) = busy.utilizationMillis()
    checkEqual("$idle/$active", "4.0/1.0", "loop utilization accumulates idle and active, in milliseconds")
}

// --------------------------------------------------------------------------- cpu ----------

private fun cpuCorpus() {
    // The awkward field is `comm`, which is the executable name in parentheses and may contain
    // spaces and parentheses of its own — Android's process names are package names, and a
    // sandboxed WebView renderer's has a colon and brackets in it. Splitting the whole line on
    // spaces mis-numbers every field after it, which is how a reader like this reports plausible
    // nonsense instead of failing.
    val plain = "42 (node) S 1 42 42 0 -1 4194304 900 0 0 0 250 130 0 0 20 0 12 0 900 0 0"
    val parsed = NodeCpu.parse(plain)
    checkEqual(
        "${parsed?.userMicros}/${parsed?.systemMicros}",
        "2500000.0/1300000.0",
        "cpuUsage reads utime and stime from /proc/self/stat, in microseconds",
    )
    val awkward = "42 (com.reagentsystems.mouse:sandbox (1)) S 1 42 42 0 -1 4194304 900 0 0 0 250 130 0 0 20 0 12 0 900 0 0"
    checkEqual(
        NodeCpu.parse(awkward)?.userMicros.toString(),
        "2500000.0",
        "a process name containing spaces and parentheses does not shift the fields",
    )
    check(NodeCpu.parse("42 (node) S 1 2 3") == null, "a truncated /proc line answers null, not zeros")
    check(NodeCpu.parse("nonsense") == null, "a line with no comm field answers null")

    // The reader itself only works where /proc does, which is Android and not this machine.
    val live = NodeCpu.read()
    if (File("/proc/self/stat").canRead()) {
        check(live != null, "/proc/self/stat is readable here and cpuUsage answers")
    } else {
        checks += 1
        check(live == null, "with no /proc, cpuUsage answers null rather than inventing zeros")
    }
}

// ---------------------------------------------------------------------- filesystem ----------

/**
 * `NodeFs` against a real directory, and against real `node`'s own answers for the same files.
 *
 * The primitives are the whole of what Android has to get right — every RULE about when they may
 * be called lives in the shared bootstrap — so what is graded here is that each one answers what
 * the Swift block answers, INCLUDING when it answers nothing. A `null` is how every failure is
 * reported upward, so a primitive that succeeds where Swift's fails silently disables a rule
 * written somewhere else.
 */
private fun fsCorpus(node: String?, scratch: File) {
    val root = File(scratch, "fs").also { it.mkdirs() }
    val fs = NodeFs(root.toPath())

    // Paths. "/a/b" and "a/b" are the same place and ".." clamps at the root rather than escaping
    // it — the property that makes a workspace-virtual filesystem a boundary and not a suggestion.
    checkEqual(fs.normalize("a/b"), "/a/b", "a relative path is rooted")
    checkEqual(fs.normalize("/a/./b/../c"), "/a/c", "dot segments are removed")
    checkEqual(fs.normalize("/../../etc/passwd"), "/etc/passwd", "`..` clamps at the root")
    checkEqual(fs.virtualDirname("/a/b/c.js"), "/a/b", "dirname of a file")
    checkEqual(fs.virtualDirname("/a"), "/", "dirname at the root")
    check(
        fs.realPath("/../../secret").startsWith(root.toPath()),
        "no virtual path escapes the real root",
    )

    // A mount grafts a real directory in at a virtual prefix.
    val elsewhere = File(scratch, "mounted").also { it.mkdirs() }
    File(elsewhere, "there.txt").writeText("mounted")
    fs.mount("/mnt", elsewhere.toPath())
    checkEqual(fs.readText("/mnt/there.txt") ?: "<null>", "mounted", "a mount reads through to its real directory")

    // Round trips.
    check(fs.writeFile("/a/b/hello.txt", base64("héllo\n"), append = false), "writeFile creates its parent")
    checkEqual(fs.readText("/a/b/hello.txt") ?: "<null>", "héllo\n", "readFile round-trips UTF-8")
    check(fs.writeFile("/a/b/hello.txt", base64("more\n"), append = true), "writeFile appends")
    checkEqual(fs.readText("/a/b/hello.txt") ?: "<null>", "héllo\nmore\n", "append does not truncate")
    // Every byte value, which is what says the base64 hop is lossless.
    val every = ByteArray(256) { it.toByte() }
    check(fs.writeFile("/bytes.bin", Base64.getEncoder().encodeToString(every), false), "binary writes")
    checkEqual(
        Base64.getDecoder().decode(fs.readFile("/bytes.bin") ?: "").toList().toString(),
        every.toList().toString(),
        "all 256 byte values survive base64 in both directions",
    )

    // Nulls. Each of these is a rule in the bootstrap that only works because the primitive fails.
    check(fs.readFile("/nowhere.txt") == null, "readFile of a missing file is null")
    check(fs.readFile("/a/b") == null, "readFile of a DIRECTORY is null — the bootstrap's EISDIR")
    check(fs.readdir("/a/b/hello.txt") == null, "readdir of a file is null — the bootstrap's ENOTDIR")
    check(fs.readdir("/nowhere") == null, "readdir of a missing directory is null")
    check(fs.stat("/nowhere", true) == null, "stat of a missing path is null")
    check(!fs.remove("/nowhere"), "remove of a missing path is false")
    check(fs.statfs("/nowhere/deeper") == null, "statfs of a missing path is null")

    // readdir is SORTED, as `contentsOfDirectory(atPath:).sorted()` is.
    fs.writeFile("/list/z", base64("z"), false)
    fs.writeFile("/list/a", base64("a"), false)
    fs.writeFile("/list/m", base64("m"), false)
    checkEqual(fs.readdir("/list")!!.joinToString(","), "a,m,z", "readdir is sorted")

    check(fs.mkdir("/deep/er/still"), "mkdir creates intermediates")
    check(fs.mkdir("/deep/er/still"), "mkdir of an existing directory succeeds, as createDirectory does")
    check(fs.rename("/list/a", "/list/b"), "rename moves")
    check(!fs.rename("/list/b", "/list/m"), "rename onto an existing name fails, as `moveItem` does")
    check(fs.remove("/deep"), "remove deletes a whole tree")
    check(fs.stat("/deep", true) == null, "and the tree is gone")

    // A symlink must be seen AS a symlink by lstat and followed by stat — `isSymbolicLink()`
    // returning true is what the bootstrap's `lstatSync` is built on.
    val linkTarget = File(root, "linktarget.txt").also { it.writeText("target") }
    val link = File(root, "link.txt")
    val madeLink = try {
        Files.createSymbolicLink(link.toPath(), linkTarget.toPath()); true
    } catch (_: Exception) {
        false
    }
    if (madeLink) {
        check(fs.stat("/link.txt", followLinks = false)?.get("link") == true, "lstat sees a symlink")
        check(fs.stat("/link.txt", followLinks = false)?.get("file") == false, "lstat does not follow it")
        check(fs.stat("/link.txt", followLinks = true)?.get("file") == true, "stat follows it")
    } else {
        println("  SKIP: this filesystem will not make a symlink — the lstat checks need one")
    }

    // The stat SHAPE. Missing fields are the bug class this list exists for: chokidar gates every
    // entry on `4 & parseInt(stats.mode, 10)`, so an absent `mode` read as NaN and silently hid
    // every file in a watched tree while directories came through.
    val info = fs.stat("/a/b/hello.txt", true)
    check(info != null, "stat answers for a real file")
    if (info != null) {
        val want = listOf(
            "dir", "link", "file", "size", "mode", "uid", "gid", "ino", "dev", "nlink", "rdev",
            "blocks", "blksize", "mtimeMs", "atimeMs", "ctimeMs", "birthtimeMs",
        )
        checkEqual(info.keys.sorted().toString(), want.sorted().toString(), "Stats carries node's full field set")
        checkEqual(info["size"].toString(), "12.0", "stat reports the real size")
        check((info["mode"] as Int) and 4 != 0, "stat reports a real mode, not a placeholder")
        check((info["mtimeMs"] as Double) > 0.0, "stat reports a real mtime")
        check(fs.stat("/a/b", true)?.get("dir") == true, "stat knows a directory")
    }

    val space = fs.statfs("/")
    check(space != null && (space["bsize"] as Double) > 0.0, "statfs reports a real block size")
    check(space != null && (space["bavail"] as Double) > 0.0, "statfs reports available blocks")

    // chmod, and the case it exists for: a program writing a secret with mode 0o600 must not get
    // a world-readable file.
    fs.writeFile("/secret", base64("s"), false)
    if (fs.chmod("/secret", 384)) {   // 0o600
        checkEqual(
            ((fs.stat("/secret", true)?.get("mode") as Int) and 511).toString(), "384",
            "chmod sets the permission bits stat reports back",
        )
    } else {
        println("  SKIP: this filesystem has no POSIX permissions — the chmod check needs them")
    }

    // Against REAL node, for the same files. `:pkgcheck` proves an install layout by making node's
    // own resolver agree with it; this is the same move one layer down — a Stats we invented
    // cannot be graded against itself.
    if (node == null) {
        println("  SKIP: no `node` — the stat cross-check needs one")
        return
    }
    val probe = File(scratch, "statprobe.js")
    probe.writeText(
        """
        const fs = require('fs');
        const s = fs.statSync(process.argv[2]);
        console.log(JSON.stringify({ size: s.size, mode: s.mode & 511, dir: s.isDirectory(), file: s.isFile() }));
        """.trimIndent(),
    )
    val (status, text) = run(listOf(node, probe.path, File(root, "a/b/hello.txt").path), scratch)
    if (status != 0) {
        check(false, "real node could stat the same file: ${text.trim().take(200)}")
    } else {
        val ours = fs.stat("/a/b/hello.txt", true)!!
        val theirs = text.trim()
        checkEqual(
            """{"size":${(ours["size"] as Double).toLong()},"mode":${(ours["mode"] as Int) and 511},""" +
                """"dir":${ours["dir"]},"file":${ours["file"]}}""",
            theirs,
            "NodeFs.stat agrees with real node's own Stats for the same file",
        )
    }
}

private fun base64(text: String): String =
    Base64.getEncoder().encodeToString(text.toByteArray(Charsets.UTF_8))

// ------------------------------------------------------------------------ resolver ----------

/**
 * `ModuleResolver` against real `node`'s own resolver, over one real tree.
 *
 * This is the check that makes the parity claim falsifiable. A resolver graded against
 * hand-written expectations is graded against whatever its author believed node does; graded
 * against `require.resolve` in the same directory, it is graded against node. The tree is written
 * here rather than fixtured because the interesting cases — an "exports" map, a scoped package, a
 * dual package, a subpath outside the map — are three files each.
 */
private fun resolverCorpus(node: String?, scratch: File) {
    val root = File(scratch, "resolve").also { it.mkdirs() }
    fun put(path: String, text: String) {
        val file = File(root, path)
        file.parentFile.mkdirs()
        file.writeText(text)
    }
    put("package.json", """{"name":"app","main":"index.js"}""")
    put("index.js", "module.exports = 'root';")
    put("lib/util.js", "module.exports = 'util';")
    put("lib/data.json", """{"n":1}""")
    put("lib/dir/index.js", "module.exports = 'dir-index';")
    put("node_modules/plain/package.json", """{"name":"plain","main":"lib/main.js"}""")
    put("node_modules/plain/lib/main.js", "module.exports = 'plain';")
    put("node_modules/noMain/package.json", """{"name":"noMain"}""")
    put("node_modules/noMain/index.js", "module.exports = 'no-main';")
    put(
        "node_modules/@scope/mapped/package.json",
        """{"name":"@scope/mapped","exports":{".":"./main.js","./extra":"./extra.js","./glob/*":"./deep/*.js"}}""",
    )
    put("node_modules/@scope/mapped/main.js", "module.exports = 'mapped';")
    put("node_modules/@scope/mapped/extra.js", "module.exports = 'extra';")
    put("node_modules/@scope/mapped/deep/one.js", "module.exports = 'one';")
    put("node_modules/@scope/mapped/hidden.js", "module.exports = 'hidden';")
    put(
        "node_modules/dual/package.json",
        """{"name":"dual","exports":{".":{"require":"./cjs.js","import":"./esm.mjs","default":"./cjs.js"}}}""",
    )
    put("node_modules/dual/cjs.js", "module.exports = 'cjs';")
    put("node_modules/dual/esm.mjs", "export default 'esm';")
    put("lib/nested/node_modules/near/package.json", """{"name":"near","main":"n.js"}""")
    put("lib/nested/node_modules/near/n.js", "module.exports = 'near';")
    put("lib/nested/use.js", "module.exports = require('near');")

    val fs = NodeFs(root.toPath())
    val resolver = ModuleResolver(fs)

    fun id(resolution: ModuleResolver.Resolution): String = when (resolution) {
        is ModuleResolver.Resolution.Core -> "core:" + resolution.name
        is ModuleResolver.Resolution.File -> resolution.id
        is ModuleResolver.Resolution.JsonFile -> resolution.id
        is ModuleResolver.Resolution.Addon -> resolution.id
        is ModuleResolver.Resolution.NotFound -> "MODULE_NOT_FOUND"
        is ModuleResolver.Resolution.NotExported -> "ERR_PACKAGE_PATH_NOT_EXPORTED"
    }

    // Our own answers, on the cases node agrees with by construction plus the ones it cannot be
    // asked (the "import" condition, which `require.resolve` never selects).
    checkEqual(id(resolver.resolve("fs", "/")), "core:fs", "a core module resolves as core")
    checkEqual(id(resolver.resolve("node:fs", "/")), "core:fs", "the `node:` prefix is stripped")
    checkEqual(id(resolver.resolve("./lib/util", "/")), "/lib/util.js", "an extension is probed")
    checkEqual(id(resolver.resolve("./data", "/lib")), "/lib/data.json", "a .json resolves as json")
    checkEqual(id(resolver.resolve("./dir", "/lib")), "/lib/dir/index.js", "a directory falls back to index.js")
    checkEqual(id(resolver.resolve(".", "/")), "/index.js", "`require(\".\")` is a directory request")
    checkEqual(id(resolver.resolve("..", "/lib")), "/index.js", "`require(\"..\")` is one too")
    checkEqual(id(resolver.resolve("dual", "/", esm = true)), "/node_modules/dual/esm.mjs",
        "the \"import\" condition picks a dual package's ESM half")
    checkEqual(id(resolver.resolve("dual", "/", esm = false)), "/node_modules/dual/cjs.js",
        "and \"require\" picks its CommonJS half")
    checkEqual(id(resolver.resolve("near", "/lib/nested")), "/lib/nested/node_modules/near/n.js",
        "the node_modules walk starts at the requiring directory")
    checkEqual(id(resolver.resolve("plain", "/lib/nested")), "/node_modules/plain/lib/main.js",
        "and walks up when the nearer one has nothing")
    checkEqual(id(resolver.resolve("@scope/mapped/glob/one", "/")), "/node_modules/@scope/mapped/deep/one.js",
        "an \"exports\" pattern key substitutes its star")
    checkEqual(id(resolver.resolve("@scope/mapped/hidden", "/")), "ERR_PACKAGE_PATH_NOT_EXPORTED",
        "a subpath outside \"exports\" is refused rather than found on disk")

    checkEqual(
        resolver.resolvePaths("plain", "/lib/nested")?.joinToString(",") ?: "<null>",
        "/lib/nested/node_modules,/lib/node_modules,/node_modules",
        "resolve.paths is the walk-up, innermost first",
    )
    check(resolver.resolvePaths("fs", "/") == null, "resolve.paths is null for a core module")
    checkEqual(
        resolver.resolvePaths("./x", "/lib")?.joinToString(",") ?: "<null>", "/lib",
        "resolve.paths for a relative request is just the requiring directory",
    )

    // Format classification, which decides whether the loader may evaluate a file at all.
    check(resolver.isESModule("/x.mjs", "module.exports = 1;"), ".mjs is ESM whatever is in it")
    check(!resolver.isESModule("/x.cjs", "import a from 'b';"), ".cjs is CommonJS whatever is in it")
    check(resolver.isESModule("/x.js", "import a from 'b';\n"), "a .js with import statements is ESM")
    check(!resolver.isESModule("/x.js", "const a = require('b');\n"), "a .js with require is not")
    check(
        !resolver.isESModule("/x.js", "export const a = 1;\nmodule.exports = a;\n"),
        "a file with BOTH is CommonJS — the bundler output case",
    )

    // The `#imports` walk must not stop at the first package.json it meets, only at one that has
    // an "imports" map. A `break` in the wrong place there makes every nested import fail.
    put("deep/pkg/package.json", """{"name":"leaf"}""")
    put("deep/package.json", """{"name":"outer","imports":{"#dep":"./target.js"}}""")
    put("deep/target.js", "module.exports = 'imported';")
    checkEqual(
        id(resolver.resolve("#dep", "/deep/pkg")), "/deep/target.js",
        "the `#imports` walk passes a package.json that has no \"imports\" map",
    )

    val payload = resolver.loadJson("/lib/util.js")
    check(payload != null && payload.contains("\"esm\":false"), "loadModule reports a CommonJS file's format")
    check(resolver.loadJson("/nowhere.js") == null, "loadModule of a missing file is null")
    put("shebang.js", "#!/usr/bin/env node\nmodule.exports = 1;\n")
    val shebang = resolver.loadJson("/shebang.js")
    check(
        shebang != null && !shebang.contains("#!"),
        "loadModule strips a shebang — it is not JavaScript and the wrapper will not parse it",
    )

    if (node == null) {
        println("  SKIP: no `node` — the resolver cross-check needs one")
        return
    }
    // The cross-check. Each of these is a case node's own resolver can be asked directly, so our
    // answer is graded against node rather than against what someone thought node does.
    val probe = File(scratch, "resolveprobe.js")
    probe.writeText(
        """
        const request = process.argv[2], from = process.argv[3];
        try { console.log(require.resolve(request, { paths: [from] })); }
        catch (e) { console.log(e.code || 'THREW'); }
        """.trimIndent(),
    )
    val cases = listOf(
        "./lib/util" to "/", "./data" to "/lib", "./dir" to "/lib", "." to "/", ".." to "/lib",
        "plain" to "/", "noMain" to "/", "near" to "/lib/nested", "plain" to "/lib/nested",
        "@scope/mapped" to "/", "@scope/mapped/extra" to "/", "@scope/mapped/glob/one" to "/",
        "@scope/mapped/hidden" to "/", "dual" to "/", "nope" to "/", "./missing" to "/lib",
    )
    // Both sides through `canonicalPath`: on macOS the temporary directory is `/var`, which is a
    // symlink to `/private/var`, and node reports the resolved form. Comparing the two spellings
    // would report a dozen agreeing answers as failures.
    for ((request, fromDir) in cases) {
        val fromReal = fs.realPath(fromDir).toFile().canonicalPath
        val (status, text) = run(listOf(node, probe.path, request, fromReal), scratch)
        val theirs = text.trim()
        fun real(id: String) = fs.realPath(id).toFile().canonicalPath
        val ours = when (val resolution = resolver.resolve(request, fromDir)) {
            is ModuleResolver.Resolution.Core -> "core:" + resolution.name
            is ModuleResolver.Resolution.File -> real(resolution.id)
            is ModuleResolver.Resolution.JsonFile -> real(resolution.id)
            is ModuleResolver.Resolution.Addon -> real(resolution.id)
            is ModuleResolver.Resolution.NotFound -> "MODULE_NOT_FOUND"
            is ModuleResolver.Resolution.NotExported -> "ERR_PACKAGE_PATH_NOT_EXPORTED"
        }
        checkEqual(
            ours, if (status == 0) theirs else "THREW",
            "require('$request') from $fromDir resolves where real node resolves it",
        )
    }
}

// ------------------------------------------------------------------ real node ----------

private fun nodeBinary(): String? {
    for (candidate in listOf("node", "/opt/homebrew/bin/node", "/usr/local/bin/node")) {
        try {
            val process = ProcessBuilder(candidate, "--version")
                .redirectErrorStream(true).start()
            if (process.waitFor(20, TimeUnit.SECONDS) && process.exitValue() == 0) return candidate
        } catch (_: Exception) {
        }
    }
    return null
}

private fun run(command: List<String>, directory: File): Pair<Int, String> {
    val process = ProcessBuilder(command).directory(directory).redirectErrorStream(true).start()
    val text = process.inputStream.bufferedReader().readText()
    process.waitFor(120, TimeUnit.SECONDS)
    return process.exitValue() to text
}

/**
 * `node --check` on the extracted bootstrap, plus a LOAD SMOKE through the real protocol.
 *
 * The smoke is not a WebView substitute — it cannot be, and the WebView half is gated on device
 * by `NodeCheckReceiver`. What it proves is everything the two hosts share, which is nearly all
 * of it: that the five scripts load in the order the host loads them, that `__mouse` satisfies
 * everything the bootstrap reaches for while loading, and that console, process and the timer
 * ordering survive the id-registry indirection Android's bridge forces.
 *
 * It runs `NodeSmoke.PROGRAM` — the SAME program the device gate runs — and grades it with
 * `NodeSmoke.grade`, the same grader. So the on-device check's program is itself gated here, and
 * an on-device MISMATCH means the WebView rather than the corpus.
 */
private class SmokeRun(val stdout: String, val stderr: String, val exit: Int)

/**
 * Load the engine and run one program, in a directory of its own. Returns null when the load or
 * the entry threw — having already reported which.
 */
private fun runSmoke(
    node: String,
    bootstrap: String,
    parent: File,
    name: String,
    globals: String,
    program: String,
    entryPath: String,
): SmokeRun? {
    val scratch = File(parent, name).also { it.mkdirs() }
    File(scratch, "vfs").mkdirs()
    File(scratch, "node-bootstrap.js").writeText(bootstrap)
    File(scratch, "node-host.js").writeText(shimFile.readText())
    File(scratch, "stubs.js").writeText(HostBridge.deferredStubScript())
    File(scratch, "unlock.js").writeText(Bootstrap.unlockGlobalsScript(bootstrap))
    File(scratch, "globals.js").writeText(globals)
    File(scratch, "program.js").writeText(program)
    File(scratch, "entry-path.txt").writeText(entryPath)
    File(scratch, "driver.js").writeText(DRIVER)

    val (status, text) = run(listOf(node, "driver.js"), scratch)
    check(status == 0, "the $name smoke ran (exit $status)\n${text.trim().take(1500)}")
    if (status != 0) return null

    val loadError = File(scratch, "load-error.txt")
    check(
        !loadError.exists(),
        "the engine loads against the Android bridge ($name): " +
            if (loadError.exists()) loadError.readText().take(600) else "",
    )
    val entryError = File(scratch, "entry-error.txt")
    check(
        !entryError.exists(),
        "the $name program runs without throwing: " +
            if (entryError.exists()) entryError.readText().take(900) else "",
    )
    if (loadError.exists() || entryError.exists()) return null

    // The host's Stats shape must be the one NodeFs really produces, or this smoke is grading a
    // filesystem that does not ship. The driver writes its own key list; NodeFs's is the truth.
    val hostKeys = File(scratch, "statkeys.txt")
    if (hostKeys.exists()) {
        val theirs = hostKeys.readText().trim()
        val ours = NodeFs(File(scratch, "vfs").toPath()).stat("/", true)?.keys?.sorted()?.joinToString(",")
        checkEqual(theirs, ours ?: "<null>", "the driver's Stats shape is the one NodeFs produces")
    }

    return SmokeRun(
        File(scratch, "out.txt").readText(),
        File(scratch, "err.txt").readText(),
        File(scratch, "exit.txt").readText().trim().toIntOrNull() ?: -1,
    )
}

private fun nodeCorpus(bootstrap: String, scratch: File) {
    if (bootstrap.isEmpty()) return
    val node = nodeBinary()
    if (node == null) {
        println("  SKIP: no `node` on this machine — the syntax check and load smoke need one")
        return
    }

    val bootstrapFile = File(scratch, "node-bootstrap.js")
    bootstrapFile.writeText(bootstrap)
    val (syntaxStatus, syntaxText) = run(listOf(node, "--check", bootstrapFile.path), scratch)
    // AGENTS.md: `interface` as a parameter name compiles fine on the Swift side and breaks the
    // engine, because swiftc cannot see into the string. This is that check.
    check(syntaxStatus == 0, "node --check on the extracted bootstrap: ${syntaxText.trim().take(300)}")
    // The shim is JavaScript nobody compiles either, and since 3b it carries the module loader.
    val (shimStatus, shimText) = run(listOf(node, "--check", shimFile.path), scratch)
    check(shimStatus == 0, "node --check on node-host.js: ${shimText.trim().take(300)}")

    // 3a's program: console, process, timers and the tick order.
    val basic = runSmoke(
        node, bootstrap, scratch, "basic",
        NodeSmoke.CONFIG.globalsScript(), NodeSmoke.PROGRAM, NodeSmoke.ENTRY_PATH,
    )
    if (basic != null) {
        val smokeFailures = NodeSmoke.grade(basic.stdout, basic.stderr, basic.exit)
        checks += NodeSmoke.CHECK_COUNT
        failures += smokeFailures.size
        for (failure in smokeFailures) println("  FAIL: $failure")
    }

    // 3b's: the filesystem and `require` over node_modules.
    val loader = runSmoke(
        node, bootstrap, scratch, "fs",
        NodeFsSmoke.CONFIG.globalsScript(), NodeFsSmoke.PROGRAM, NodeFsSmoke.ENTRY_PATH,
    )
    if (loader != null) {
        val loaderFailures = NodeFsSmoke.grade(loader.stdout, loader.stderr, loader.exit)
        checks += NodeFsSmoke.CHECK_COUNT
        failures += loaderFailures.size
        for (failure in loaderFailures) println("  FAIL: $failure")
    }

    fsParityCorpus(node, bootstrap, scratch)
}

/**
 * `verify/fsparity`, run through the Android bridge and graded against the SAME `node.txt`.
 *
 * Read from `verify/` directly rather than copied, exactly as `:screencheck` reads its corpus: a
 * fixture that has been copied is a fixture that can drift, and a parity claim gated against a
 * different file from the one iOS is gated against is unfalsifiable.
 *
 * What it proves that `NodeFsSmoke` does not is the whole ERROR family — ENOENT, EISDIR, EEXIST,
 * ENOTDIR, ENOTEMPTY, ERR_FS_EISDIR — across all three of the sync, callback and promise forms of
 * each operation. Those rules live in the shared bootstrap, and they work only because the host
 * primitives fail where they are supposed to.
 */
private fun fsParityCorpus(node: String, bootstrap: String, scratch: File) {
    val script = File(repoRoot, "verify/fsparity/script.js")
    val expectedFile = File(repoRoot, "verify/fsparity/node.txt")
    check(script.exists() && expectedFile.exists(), "verify/fsparity is where the harness reads it from")
    if (!script.exists() || !expectedFile.exists()) return

    val run = runSmoke(
        node, bootstrap, scratch, "fsparity",
        NodeProcessConfig(argv = listOf("node", "/script.js"), cwd = "/").globalsScript(),
        script.readText(), "/script.js",
    ) ?: return

    val expected = expectedFile.readText().trim().lines()
    val ours = run.stdout.trim().lines()
    var wrong = 0
    for (i in 0 until maxOf(expected.size, ours.size)) {
        val want = expected.getOrNull(i) ?: "<missing>"
        val got = ours.getOrNull(i) ?: "<missing>"
        if (want != got) {
            wrong += 1
            println("  FAIL: fs parity line ${i + 1}\n      node: $want\n      ours: $got")
        }
    }
    checks += expected.size
    failures += wrong
    // The script's own internal check: an operation whose sync, callback and promise forms
    // disagree marks itself, and that is a failure even when all three agree with node.
    val inconsistent = ours.count { it.contains("DIVERGES") }
    check(inconsistent == 0, "no fs operation disagrees across its own three forms ($inconsistent do)")
}

/**
 * The load smoke's driver, in JavaScript, because that is the only language both halves speak.
 *
 * It stands in for NodeWebView: the same five scripts in the same order, the same `__mouseHost`
 * method set, the same id-registry timer protocol, and the same one-turn-per-dispatch loop — with
 * a REAL macrotask boundary between turns, which is what an `evaluateJavascript` call is. The
 * clock is virtual, so the smoke costs no wall time and cannot flake on a slow machine.
 *
 * ## What the stand-in stands in for, and what it does not
 *
 * The HOST here is a stand-in; the thing under test is everything above it — `node-host.js` (which
 * since 3b carries the module loader), the bootstrap, and the protocol between them. So its
 * filesystem is node's own `fs` over a real scratch directory, and its resolver is node's own
 * `require.resolve` in that directory. That is deliberately not a second implementation of
 * `NodeFs`/`ModuleResolver`: a JavaScript copy of those rules would be one more thing that can
 * drift, and grading our loader against our own resolver would prove nothing about either.
 *
 * The Kotlin halves are graded separately and more strictly — `fsCorpus` against real node's own
 * `Stats`, `resolverCorpus` against real node's own `require.resolve`, case by case. The two meet
 * for the first time on a device, which is what `NodeCheckReceiver` is for.
 */
private val DRIVER = """
    'use strict';
    const fs = require('fs');
    const nodePath = require('path');

    // Real node's, captured BEFORE the bootstrap replaces the globals with the engine's. After
    // the load, `console` writes into the engine's stdout sink and `setImmediate` is the engine's
    // — a driver that had not saved these would be reporting into the thing it is testing.
    const realProcess = process;
    const realSetImmediate = setImmediate;

    // `process.exit()` unwinds by throwing a sentinel, AFTER `bridge.exit` has already recorded
    // the code. Thrown from a synchronous frame the shim catches it; thrown from an async
    // continuation it lands in the microtask checkpoint at the END of a turn — outside any
    // try/catch on either host. A WebView reports that to its console and carries on with the
    // exit code already recorded, so the run still ends correctly; this driver runs under real
    // node, where an unhandled rejection is fatal, so it has to say the same thing explicitly.
    // Anything else is a genuine failure and is recorded for the harness to read.
    realProcess.on('unhandledRejection', (reason) => {
      const text = (reason && reason.message) ? String(reason.message) : String(reason);
      if (text.indexOf('__mouse_exit__') >= 0) return;
      fs.writeFileSync('entry-error.txt', 'unhandled rejection: '
        + ((reason && reason.stack) ? String(reason.stack) : text));
    });

    // ---- the host, in the shape NodeWebView implements it ----
    let nextId = 1;
    const timers = new Map();       // id -> { due, interval, refed }
    let immediates = [];
    let exitCode = null;
    let holds = 0, stdinActive = false;
    let clock = 0;                  // virtual milliseconds
    let stdout = '', stderr = '';

    globalThis.__mouseHost = {
      asset: (name) => fs.readFileSync(name, 'utf8'),
      stdout: (text) => { stdout += text; },
      stderr: (text) => { stderr += text; },
      exit: (code) => { if (exitCode === null) exitCode = code; },
      monotonicNanos: () => String(clock * 1000000),
      setTimer: (delay, repeat) => {
        const id = nextId++;
        const ms = Math.max(1, delay);
        timers.set(id, { due: clock + ms, interval: repeat ? ms : null, refed: true });
        return id;
      },
      clearTimer: (id) => { timers.delete(id); },
      timerRef: (id, refed) => { const t = timers.get(id); if (t) t.refed = refed; },
      timerRefresh: (id) => { const t = timers.get(id); if (t) t.due = clock + (t.interval || 1); },
      setImmediate: () => { const id = nextId++; immediates.push(id); return id; },
      clearImmediate: (id) => { const at = immediates.indexOf(id); if (at >= 0) immediates.splice(at, 1); },
      loopHold: (on) => { holds += on ? 1 : -1; },
      stdinActive: (on) => { stdinActive = on; },

      // ---- the filesystem, workspace-virtual over ./vfs ----
      stat: (p, follow) => statJson(p, follow),
      statfs: (p) => { try { fs.accessSync(real(p)); } catch (e) { return null; }
        return JSON.stringify({ type: 0, bsize: 4096, blocks: 1e6, bfree: 5e5, bavail: 5e5, files: 0, ffree: 0 }); },
      readdir: (p) => { try { return JSON.stringify(fs.readdirSync(real(p)).sort()); } catch (e) { return null; } },
      readFile: (p) => { try { if (fs.statSync(real(p)).isDirectory()) return null;
        return fs.readFileSync(real(p)).toString('base64'); } catch (e) { return null; } },
      readText: (p) => { try { if (fs.statSync(real(p)).isDirectory()) return null;
        return fs.readFileSync(real(p), 'utf8'); } catch (e) { return null; } },
      writeFile: (p, base64, append) => {
        try {
          const target = real(p);
          fs.mkdirSync(nodePath.dirname(target), { recursive: true });
          const data = Buffer.from(base64, 'base64');
          if (append && fs.existsSync(target)) fs.appendFileSync(target, data); else fs.writeFileSync(target, data);
          return true;
        } catch (e) { return false; }
      },
      mkdir: (p) => { try { fs.mkdirSync(real(p), { recursive: true }); return true; } catch (e) { return false; } },
      remove: (p) => { try { if (!fs.existsSync(real(p)) && !isLink(real(p))) return false;
        fs.rmSync(real(p), { recursive: true, force: true }); return true; } catch (e) { return false; } },
      rename: (from, to) => { try { if (fs.existsSync(real(to))) return false;
        fs.renameSync(real(from), real(to)); return true; } catch (e) { return false; } },
      chmodPath: (p, mode) => { try { fs.chmodSync(real(p), mode); return true; } catch (e) { return false; } },
      normalizePath: (p) => normalize(p),
      virtualDirname: (p) => virtualDirname(p),

      // ---- module resolution: node's own, in the same directory ----
      resolveModule: (request, fromDir, esm) => resolveJson(request, fromDir, esm),
      resolvePaths: (request, fromDir) => JSON.stringify(resolvePaths(request, fromDir)),
      loadModule: (id) => loadModuleJson(id),

      // `realProcess`, not `process`: after the bootstrap loads, the global `process` is the
      // ENGINE's, whose cpuUsage() calls straight back into this method. The stack overflow that
      // produced was the only symptom.
      cpuUsage: () => { const u = realProcess.cpuUsage(); return JSON.stringify({ user: u.user, system: u.system }); },
      loopUtilization: () => JSON.stringify({ idle: clock, active: 0 }),
      setRawMode: () => {},
    };

    // ---- workspace-virtual paths, the one rule the stand-in must copy exactly ----
    // Through realpath: on macOS the temporary directory is a symlink, and node reports resolved
    // paths, so a VROOT spelled the other way makes every `relative()` climb out of the tree.
    const VROOT = fs.realpathSync(nodePath.resolve('vfs'));
    function normalize(p) {
      const parts = [];
      for (const piece of String(p).split('/')) {
        if (!piece || piece === '.') continue;
        if (piece === '..') { parts.pop(); continue; }
        parts.push(piece);
      }
      return '/' + parts.join('/');
    }
    function virtualDirname(p) {
      const n = normalize(p);
      const slash = n.lastIndexOf('/');
      return slash <= 0 ? '/' : n.slice(0, slash);
    }
    const real = (p) => nodePath.join(VROOT, normalize(p));
    const virtual = (p) => normalize('/' + nodePath.relative(VROOT, p));
    const isLink = (p) => { try { return fs.lstatSync(p).isSymbolicLink(); } catch (e) { return false; } };

    // The Stats key set is NodeFs's, and the harness checks that claim rather than taking it.
    const STAT_KEYS = ['atimeMs','birthtimeMs','blksize','blocks','ctimeMs','dev','dir','file','gid',
                       'ino','link','mode','mtimeMs','nlink','rdev','size','uid'];
    fs.writeFileSync('statkeys.txt', STAT_KEYS.join(','));
    function statJson(p, follow) {
      let s;
      try { s = follow ? fs.statSync(real(p)) : fs.lstatSync(real(p)); } catch (e) { return null; }
      return JSON.stringify({
        dir: s.isDirectory(), link: s.isSymbolicLink(), file: s.isFile(), size: s.size,
        mode: s.mode, uid: s.uid, gid: s.gid, ino: s.ino, dev: s.dev, nlink: s.nlink,
        rdev: s.rdev, blocks: s.blocks, blksize: s.blksize,
        mtimeMs: s.mtimeMs, atimeMs: s.atimeMs, ctimeMs: s.ctimeMs, birthtimeMs: s.birthtimeMs,
      });
    }

    const CORE = new Set(['fs','path','os','util','events','buffer','tty','assert','url','child_process',
      'http','https','net','crypto','stream','zlib','readline','readline/promises','string_decoder',
      'constants','querystring','fs/promises','stream/promises','process','module','timers',
      'timers/promises','path/posix','path/win32','http2','tls','dns','worker_threads','async_hooks',
      'v8','vm','perf_hooks','inspector','dgram','cluster','diagnostics_channel','console','util/types',
      'domain','wasi']);

    function resolveJson(request, fromDir, esm) {
      const bare = request.startsWith('node:') ? request.slice(5) : request;
      if (CORE.has(bare)) return JSON.stringify({ kind: 'core', id: bare });
      // A path specifier names a place in the VIRTUAL filesystem, so it is translated before node
      // sees it; a bare one is a package name and travels as written, with the requiring
      // directory's real path as the search root.
      let target = request;
      const relative = request === '.' || request === '..'
        || request.startsWith('./') || request.startsWith('../');
      if (request.startsWith('/')) target = real(request);
      else if (relative) target = nodePath.join(real(fromDir), request);
      let resolved;
      try {
        resolved = require.resolve(target, { paths: [real(fromDir)] });
      } catch (e) {
        return JSON.stringify({ kind: 'error', message: e.message, code: e.code || 'MODULE_NOT_FOUND' });
      }
      const id = virtual(resolved);
      const kind = id.endsWith('.json') ? 'json' : id.endsWith('.node') ? 'addon' : 'file';
      if (kind === 'addon') {
        return JSON.stringify({ kind: 'addon', id: id, code: 'ERR_DLOPEN_FAILED',
          message: "Cannot load '" + id + "': a .node addon is compiled machine code" });
      }
      return JSON.stringify({ kind: kind, id: id });
    }

    function resolvePaths(request, fromDir) {
      const bare = request.startsWith('node:') ? request.slice(5) : request;
      if (CORE.has(bare)) return null;
      if (request === '.' || request === '..' || request.startsWith('./') || request.startsWith('../')) {
        return [fromDir || '/'];
      }
      const out = [];
      let dir = fromDir || '/';
      for (;;) {
        out.push(dir === '/' ? '/node_modules' : dir + '/node_modules');
        if (dir === '/' || !dir) break;
        dir = virtualDirname(dir);
      }
      return out;
    }

    function loadModuleJson(id) {
      let source;
      try { source = fs.readFileSync(real(id), 'utf8'); } catch (e) { return null; }
      if (source.slice(0, 2) === '#!') { const nl = source.indexOf('\n'); source = nl < 0 ? '' : source.slice(nl); }
      return JSON.stringify({ source: source, esm: isESModule(id, source) });
    }

    function isESModule(id, source) {
      if (id.endsWith('.mjs')) return true;
      if (id.endsWith('.cjs')) return false;
      let dir = virtualDirname(id);
      for (;;) {
        try {
          const pkg = JSON.parse(fs.readFileSync(real(dir + '/package.json'), 'utf8'));
          if ((pkg.type || 'commonjs') === 'module') return true;
          break;
        } catch (e) {}
        if (dir === '/' || !dir) break;
        dir = virtualDirname(dir);
      }
      return /^\s*(import\s+[\w{*'"]|import\s*\(|export\s+(default|const|let|var|function|class|\{|\*))/m.test(source)
        && !/^\s*(module\.exports|exports\.)/m.test(source);
    }

    const evalGuarded = (source, label) => {
      try { (0, eval)(source + '\n//# sourceURL=' + label); return null; }
      catch (e) { return (e && e.stack) ? String(e.stack) : String(e); }
    };
    const die = (text) => { fs.writeFileSync('load-error.txt', String(text)); realProcess.exit(0); };

    // ---- the load, in NodeWebView's order ----
    let error = evalGuarded(fs.readFileSync('node-host.js', 'utf8'), 'node-host.js');
    if (error) die('node-host.js: ' + error);
    error = globalThis.__mouseEval(fs.readFileSync('stubs.js', 'utf8'), 'stubs.js');
    if (error) die('stubs: ' + error);
    error = globalThis.__mouseEval(fs.readFileSync('unlock.js', 'utf8'), 'unlock.js');
    if (error) die('unlock: ' + error);
    error = globalThis.__mouseEval(fs.readFileSync('globals.js', 'utf8'), 'globals.js');
    if (error) die('globals: ' + error);
    error = globalThis.__mouseEvalAsset('node-bootstrap.js');
    if (error) die('node-bootstrap.js: ' + error);

    // ---- the loop ----
    // One turn is exactly NodeWebView.pump(): ready immediates as a batch, else the earliest due
    // timer, else advance to the next due time — and quiescence (no ref'd timer, no hold, no
    // stdin listener) ends it.
    const turn = () => {
      if (exitCode !== null) return false;
      if (immediates.length) {
        const batch = immediates;
        immediates = [];
        globalThis.__mouseDispatch.immediates(batch);
        return true;
      }
      let due = null;
      for (const [id, t] of timers) {
        if (t.due <= clock && (due === null || t.due < timers.get(due).due)) due = id;
      }
      if (due !== null) {
        const t = timers.get(due);
        if (t.interval !== null) t.due = clock + t.interval; else timers.delete(due);
        globalThis.__mouseDispatch.timer(due);
        return true;
      }
      const quiet = holds === 0 && !stdinActive && ![...timers.values()].some((t) => t.refed);
      if (quiet) return false;
      let soonest = null;
      for (const t of timers.values()) if (soonest === null || t.due < soonest) soonest = t.due;
      if (soonest === null) return false;
      clock = soonest;
      return true;
    };

    // A REAL macrotask between turns. Each turn is one evaluateJavascript call on Android, and the
    // microtask checkpoint that runs as it ends is half of the tick discipline — a driver that
    // spun synchronously would never let a promise reaction run and would grade the ordering
    // wrong, in the engine's favour.
    const yieldTurn = () => new Promise((resolve) => realSetImmediate(resolve));

    (async () => {
      const result = JSON.parse(globalThis.__mouseDispatch.entry(
        fs.readFileSync('program.js', 'utf8'), fs.readFileSync('entry-path.txt', 'utf8').trim()));
      if (!result.ok) fs.writeFileSync('entry-error.txt', String(result.error));
      let n = 0;
      while (n++ < 2000) {
        await yieldTurn();
        if (!turn()) break;
      }
      globalThis.__mouseDispatch.finish();
      fs.writeFileSync('out.txt', stdout);
      fs.writeFileSync('err.txt', stderr);
      fs.writeFileSync('exit.txt', String(exitCode));
    })();
""".trimIndent()


// -------------------------------------------------------------------------- main ----------

fun main(args: Array<String>) {
    val sync = args.contains("--sync")
    if (sync) {
        val extracted = Bootstrap.extract(swiftFile.readText())
        assetFile.parentFile.mkdirs()
        assetFile.writeText(extracted)
        println(
            "SYNCED ${Bootstrap.ASSET_PATH} from ${Bootstrap.SWIFT_PATH} " +
                "(${extracted.count { it == '\n' }} lines, ${extracted.length} chars)",
        )
        return
    }

    println("nodecheck — the Android Node layer's portable half (sources from ${repoRoot.path})")
    val bootstrap = driftCorpus()
    bridgeCorpus(bootstrap)
    globalsCorpus(bootstrap)
    loopCorpus()
    cpuCorpus()

    val scratch = File(System.getProperty("java.io.tmpdir"), "nodecheck-${ProcessHandle.current().pid()}")
    scratch.mkdirs()
    try {
        val node = nodeBinary()
        fsCorpus(node, scratch)
        resolverCorpus(node, scratch)
        nodeCorpus(bootstrap, scratch)
    } finally {
        scratch.deleteRecursively()
    }

    if (failures == 0) {
        println(
            "NODE LAYER: $checks checks — bootstrap drift vs swift/Mouse/NodeEngine.swift, bridge " +
                "partition, process globals, event loop, cpu time, filesystem and module " +
                "resolution vs real node, node --check, load smoke, verify/fsparity — MATCH",
        )
    } else {
        println("NODE LAYER: $failures of $checks checks failed — MISMATCH")
        exitProcess(1)
    }
}
