package com.reagentsystems.mouse.nodecheck

import com.reagentsystems.mouse.node.Bootstrap
import com.reagentsystems.mouse.node.HostBridge
import com.reagentsystems.mouse.node.ModuleResolver
import com.reagentsystems.mouse.node.NodeCpu
import com.reagentsystems.mouse.node.NodeFs
import com.reagentsystems.mouse.node.NodeFsSmoke
import com.reagentsystems.mouse.node.NodeLoop
import com.reagentsystems.mouse.node.NodeDns
import com.reagentsystems.mouse.node.NodeHttp
import com.reagentsystems.mouse.node.NodeProcessConfig
import com.reagentsystems.mouse.node.NodeSmoke
import com.reagentsystems.mouse.node.NodeSocketSmoke
import com.reagentsystems.mouse.node.NodeSockets
import com.reagentsystems.mouse.packages.Json
import java.io.File
import java.io.IOException
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.nio.file.Files
import java.util.Base64
import java.util.concurrent.ConcurrentLinkedQueue
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

// ------------------------------------------------------------------- sockets ----

/**
 * A recorder for what [NodeSockets] hands back.
 *
 * The table talks in `(handlerId, argsJson, final)`, which is the wire the WebView carries. Parsing
 * it here rather than inspecting the table's internals is deliberate: what the gate must grade is
 * what JavaScript would SEE, and an assertion against a private field would pass just as happily
 * against a table that never delivered anything.
 */
private class SocketRecorder {
    private val lock = Object()
    private val events = ArrayList<Triple<Int, String, Any?>>()
    var holds = 0
        private set

    /** One-shot answers — `resolve`, `sendDatagram` — which are argument lists, not socket events. */
    private val answers = HashMap<Int, List<*>>()

    val post: (Int, String, Boolean) -> Unit = { handlerId, argsJson, _ ->
        val args = Json.parse(argsJson) as? List<*>
        synchronized(lock) {
            // A socket event is `(id, name, payload)`; anything else is a one-shot callback's
            // argument list. Filing them apart rather than dropping the second shape matters —
            // the first version of this recorder silently discarded every `resolve` answer, and
            // the check that read them could not fail.
            if (args != null && args.size == 3 && args[0] is Number && args[1] is String) {
                events.add(Triple((args[0] as Number).toInt(), args[1] as String, args[2]))
            } else if (args != null) {
                answers[handlerId] = args
            }
            lock.notifyAll()
        }
    }

    fun answer(handlerId: Int): List<*>? = synchronized(lock) { answers[handlerId] }

    fun awaitAnswer(handlerId: Int, timeoutMs: Long = 10_000): List<*>? {
        await(timeoutMs) { synchronized(lock) { answers.containsKey(handlerId) } }
        return answer(handlerId)
    }
    val retain: () -> Unit = { synchronized(lock) { holds += 1; lock.notifyAll() } }
    val release: () -> Unit = { synchronized(lock) { holds -= 1; lock.notifyAll() } }

    /** Every event so far, as `id:name`, in order. */
    fun trace(id: Int? = null): String = synchronized(lock) {
        events.filter { id == null || it.first == id }.joinToString(",") { it.second }
    }

    fun payload(id: Int, name: String): Any? =
        synchronized(lock) { events.lastOrNull { it.first == id && it.second == name }?.third }

    /** Everything a socket received, reassembled from the base64 chunks. */
    fun data(id: Int): String = synchronized(lock) {
        events.filter { it.first == id && it.second == "data" }
            .joinToString("") { String(Base64.getDecoder().decode(it.third as String), Charsets.UTF_8) }
    }

    fun dataBytes(id: Int): Int = synchronized(lock) {
        events.filter { it.first == id && it.second == "data" }
            .sumOf { Base64.getDecoder().decode(it.third as String).size }
    }

    /** Wait until [ready] holds, or give up. A gate that hangs is worse than one that fails. */
    fun await(timeoutMs: Long = 5_000, ready: () -> Boolean): Boolean {
        val deadline = System.currentTimeMillis() + timeoutMs
        synchronized(lock) {
            while (!ready()) {
                val left = deadline - System.currentTimeMillis()
                if (left <= 0) return false
                lock.wait(left.coerceAtMost(100))
            }
        }
        return true
    }

    fun has(id: Int, name: String, timeoutMs: Long = 5_000): Boolean =
        await(timeoutMs) { synchronized(lock) { events.any { it.first == id && it.second == name } } }

    /** The id a server reported for the connection it accepted. */
    fun acceptedId(serverId: Int): Int? = synchronized(lock) {
        val payload = events.firstOrNull { it.first == serverId && it.second == "connection" }?.third
        ((payload as? Map<*, *>)?.get("id") as? Number)?.toInt()
    }

    fun port(id: Int, name: String): Int =
        (((payload(id, name) as? Map<*, *>)?.get("port")) as? Number)?.toInt() ?: 0
}

/**
 * `NodeSockets` — the Java NIO table itself — against real peers on a real wire.
 *
 * This is the socket layer's answer to `fsCorpus`, and it is the check the JavaScript stand-in in
 * [DRIVER] cannot make: that stand-in is real node's own `net`, which proves the shim and the
 * bootstrap above it and says nothing at all about the Kotlin underneath. Here the table is driven
 * directly and the peer is a real socket — a plain JVM one for the deterministic cases, and REAL
 * `node` for the two that matter most.
 *
 * AGENTS.md on this layer: "it works when both ends are ours proves nothing about the wire".
 */
private fun socketsCorpus(node: String?) {
    val recorder = SocketRecorder()
    val table = NodeSockets(recorder.post, recorder.retain, recorder.release)
    try {
        // --- listen, accept, echo, and each side's own event sequence ---
        val serverId = table.listen("127.0.0.1", 0, 511)
        check(recorder.has(serverId, "listening"), "listen(0) reports `listening`")
        val port = recorder.port(serverId, "listening")
        check(port > 0, "listen(0) binds an ephemeral port and names it ($port)")
        checkEqual(
            ((recorder.payload(serverId, "listening") as? Map<*, *>)?.get("family")).toString(),
            "IPv4", "the listening address carries its family",
        )

        val peer = Socket()
        peer.connect(InetSocketAddress("127.0.0.1", port), 5_000)
        check(recorder.has(serverId, "connection"), "a connecting peer becomes a `connection`")
        val accepted = recorder.acceptedId(serverId)
        check(accepted != null && accepted != serverId, "the accepted socket has an id of its own")
        if (accepted != null) {
            // An accepted socket's events are delivered under the SERVER's handler id. That is
            // what closes the window where a connection exists with nothing listening for it, and
            // the recorder groups by the EVENT's id, so this also proves the two are separate.
            peer.getOutputStream().write("ping".toByteArray())
            peer.getOutputStream().flush()
            check(recorder.has(accepted, "data"), "bytes from the peer arrive as `data`")
            checkEqual(recorder.data(accepted), "ping", "and they arrive intact")

            check(table.write(accepted, "echo:ping".toByteArray()), "a small write is accepted without backpressure")
            val back = ByteArray(9)
            peer.soTimeout = 5_000
            var read = 0
            while (read < back.size) {
                val n = peer.getInputStream().read(back, read, back.size - read)
                if (n < 0) break
                read += n
            }
            checkEqual(String(back, 0, read), "echo:ping", "the peer receives what we wrote")

            // EOF is not a close. The peer's FIN means no more data; the fd retires only when
            // BOTH directions are done — so `end` must arrive without `close` behind it.
            peer.shutdownOutput()
            check(recorder.has(accepted, "end"), "the peer's FIN arrives as `end`")
            check(
                !recorder.has(accepted, "close", timeoutMs = 300),
                "a half-closed socket is still open — EOF is not a close",
            )
            table.end(accepted)
            check(recorder.has(accepted, "close"), "and it closes once both directions are done")
            checkEqual(
                recorder.trace(accepted), "data,end,close",
                "an accepted socket's own event sequence",
            )
        }
        peer.close()
        table.destroy(serverId)
        check(recorder.has(serverId, "close"), "destroying a server closes it")

        // --- connect out, to a real JVM peer ---
        ServerSocket(0, 50, InetAddress.getByName("127.0.0.1")).use { listener ->
            val clientId = table.connect("127.0.0.1", listener.localPort)
            val incoming = listener.accept()
            check(recorder.has(clientId, "connect"), "connect() reports `connect`")
            checkEqual(
                recorder.port(clientId, "connect").toString(), "0",
                "the connect payload nests local/remote rather than carrying a bare port",
            )
            val remote = ((recorder.payload(clientId, "connect") as? Map<*, *>)?.get("remote")) as? Map<*, *>
            checkEqual(
                ((remote?.get("port")) as? Number)?.toInt().toString(), listener.localPort.toString(),
                "a connected socket knows its peer's port",
            )
            table.write(clientId, "hello".toByteArray())
            val buffer = ByteArray(5)
            incoming.soTimeout = 5_000
            incoming.getInputStream().read(buffer)
            checkEqual(String(buffer), "hello", "an outbound socket writes")
            incoming.getOutputStream().write("world".toByteArray())
            incoming.getOutputStream().flush()
            check(recorder.has(clientId, "data"), "and reads")
            checkEqual(recorder.data(clientId), "world", "with the bytes intact")
            incoming.close()
            check(recorder.has(clientId, "end"), "the peer closing reports `end`")
            table.end(clientId)
            check(recorder.has(clientId, "close"), "and then `close`")
        }

        // --- the error paths, which real code branches on ---
        val refused = table.connect("127.0.0.1", 1)
        check(recorder.has(refused, "error"), "a refused connect reports an error")
        checkEqual(
            ((recorder.payload(refused, "error") as? Map<*, *>)?.get("code")).toString(),
            "ECONNREFUSED", "with node's own code",
        )
        check(recorder.has(refused, "close"), "and closes afterwards — an error with no close is a hang")

        ServerSocket(0, 50, InetAddress.getByName("127.0.0.1")).use { taken ->
            val clash = table.listen("127.0.0.1", taken.localPort, 511)
            check(recorder.has(clash, "error"), "binding a taken port reports an error rather than throwing")
            checkEqual(
                ((recorder.payload(clash, "error") as? Map<*, *>)?.get("code")).toString(),
                "EADDRINUSE", "and the code is EADDRINUSE",
            )
        }
        val missing = table.connect("this-name-does-not-exist-mouse.invalid", 80)
        check(recorder.has(missing, "error", timeoutMs = 15_000), "connecting to an unresolvable host reports an error")
        checkEqual(
            ((recorder.payload(missing, "error") as? Map<*, *>)?.get("code")).toString(),
            "ENOTFOUND", "and the code is ENOTFOUND — a hang is a worse bug than an error",
        )

        // --- backpressure, and that no byte is lost through it ---
        ServerSocket(0, 50, InetAddress.getByName("127.0.0.1")).use { sink ->
            val id = table.connect("127.0.0.1", sink.localPort)
            val incoming = sink.accept()
            check(recorder.has(id, "connect"), "the backpressure socket connected")
            val megabyte = ByteArray(1024 * 1024) { 'a'.code.toByte() }
            // The peer is not reading, so the kernel queue fills and `write` must eventually say
            // so. A table that always answered true would look identical until a real transfer.
            var refusedOnce = false
            for (chunk in 0 until 16) {
                if (!table.write(id, megabyte.copyOfRange(chunk * 65536, (chunk + 1) * 65536))) {
                    refusedOnce = true
                }
            }
            check(refusedOnce, "a write past the high-water mark answers false")
            var total = 0
            val buffer = ByteArray(65536)
            incoming.soTimeout = 10_000
            while (total < 1024 * 1024) {
                val n = incoming.getInputStream().read(buffer)
                if (n < 0) break
                total += n
            }
            checkEqual(total.toString(), (1024 * 1024).toString(), "and every byte still arrives")
            check(recorder.has(id, "drain"), "the queue emptying reports `drain`")
            incoming.close()
            table.destroy(id)
        }

        // --- pause and resume must not lose bytes ---
        ServerSocket(0, 50, InetAddress.getByName("127.0.0.1")).use { listener ->
            val id = table.connect("127.0.0.1", listener.localPort)
            val incoming = listener.accept()
            check(recorder.has(id, "connect"), "the pause socket connected")
            table.pause(id)
            Thread.sleep(50)
            incoming.getOutputStream().write(ByteArray(4096) { 'x'.code.toByte() })
            incoming.getOutputStream().flush()
            Thread.sleep(200)
            checkEqual(
                recorder.dataBytes(id).toString(), "0",
                "a paused socket delivers nothing — `http` pauses between requests",
            )
            table.resume(id)
            check(recorder.await { recorder.dataBytes(id) == 4096 }, "resume replays every buffered byte")
            incoming.close()
            table.destroy(id)
        }

        // --- ref/unref: whether a handle is a reason to stay alive ---
        val held = table.listen("127.0.0.1", 0, 511)
        check(recorder.has(held, "listening"), "the unref server bound")
        val before = recorder.holds
        table.setRef(held, false)
        check(recorder.await { recorder.holds == before - 1 }, "unref() gives the loop handle back without closing")
        table.setRef(held, true)
        check(recorder.await { recorder.holds == before }, "and ref() takes it again")
        table.destroy(held)

        // --- getaddrinfo, which is what `dns.lookup` is ---
        val lookup = table.claimExternalId()
        table.resolve(lookup, "localhost", 0)
        val resolved = recorder.awaitAnswer(lookup)
        check(resolved != null, "dns.lookup answers for `localhost`")
        @Suppress("UNCHECKED_CAST")
        val addresses = (resolved?.firstOrNull() as? List<Map<String, Any?>>).orEmpty()
        checkEqual((resolved?.getOrNull(1) as? String) ?: "<none>", "", "and reports no error")
        check(
            addresses.any { it["address"] == "127.0.0.1" || it["address"] == "0:0:0:0:0:0:0:1" || it["address"] == "::1" },
            "and the address is a loopback one (${addresses.map { it["address"] }})",
        )
        check(
            addresses.all { (it["family"] as? Number)?.toInt() == 4 || (it["family"] as? Number)?.toInt() == 6 },
            "each address carries family 4 or 6, as dns.lookup reports it",
        )
        val nowhere = table.claimExternalId()
        table.resolve(nowhere, "this-name-does-not-exist-mouse.invalid", 0)
        checkEqual(
            (recorder.awaitAnswer(nowhere)?.getOrNull(1) as? String) ?: "<none>", "ENOTFOUND",
            "an unresolvable name answers ENOTFOUND rather than an empty list",
        )

        // --- UDP ---
        val udp = table.bindDatagram("127.0.0.1", 0, false)
        check(recorder.has(udp, "listening"), "a datagram socket binds")
        val udpPort = recorder.port(udp, "listening")
        val sender = table.claimExternalId()
        table.sendDatagram(sender, udp, "udp-hello".toByteArray(), "127.0.0.1", udpPort)
        // The empty string is SUCCESS here, and that is the iOS rule this layer paid for once:
        // coalescing "no problem" to a code reported every successful send as a failure.
        checkEqual(
            (recorder.awaitAnswer(sender)?.firstOrNull() as? String) ?: "<none>", "",
            "dgram.send reports success as the EMPTY string, not as a code",
        )
        check(recorder.has(udp, "datagram"), "a datagram arrives whole")
        val datagram = recorder.payload(udp, "datagram") as? Map<*, *>
        checkEqual(
            String(Base64.getDecoder().decode(datagram?.get("data") as? String ?: ""), Charsets.UTF_8),
            "udp-hello", "with its content intact",
        )
        check(
            (((datagram?.get("from") as? Map<*, *>)?.get("port")) as? Number)?.toInt() ?: 0 > 0,
            "and with its sender's port — UDP has no connection to hang it on",
        )
        table.destroy(udp)

        // --- the error-code map, which is what real code branches on ---
        checkEqual(table.codeFor(java.net.ConnectException("Connection refused")), "ECONNREFUSED", "ConnectException maps to ECONNREFUSED")
        checkEqual(table.codeFor(java.net.BindException("Address already in use")), "EADDRINUSE", "BindException maps to EADDRINUSE")
        checkEqual(table.codeFor(java.net.UnknownHostException("nope")), "ENOTFOUND", "UnknownHostException maps to ENOTFOUND")
        checkEqual(table.codeFor(java.io.IOException("Broken pipe")), "EPIPE", "a broken pipe maps to EPIPE")
        checkEqual(table.codeFor(java.io.IOException("Connection reset by peer")), "ECONNRESET", "a reset maps to ECONNRESET")

        crossEngineCorpus(node, table, recorder)
    } finally {
        table.closeAll()
    }
    shutdownRaceCorpus()
}

/**
 * `closeAll()` while the selector thread is mid-pass — and what it must NOT raise.
 *
 * This check exists because the JVM and Android disagree about the consequences of an uncaught
 * exception on a daemon thread. On the JVM it prints a stack trace and that thread dies; the
 * harness around it carries on and every other check still passes. On Android the default handler
 * kills the process. So a shutdown race here is INVISIBLE to an ordinary headless check and fatal
 * on a phone, which is exactly how one shipped: `closeAll` closes the selector, and a pass already
 * past `select()` then called `selectedKeys()` on it and got `ClosedSelectorException` — unchecked,
 * so neither of the loop's catch clauses saw it.
 *
 * Making it visible off-device takes the one thing the platforms share: the handler itself. The
 * table is torn down under live traffic, repeatedly — parked in `select()` the race cannot happen,
 * so a socket has to be mid-event — and anything that reaches the selector thread's handler is a
 * failure by name rather than a line on stderr nobody reads.
 */
private fun shutdownRaceCorpus() {
    val raised = ConcurrentLinkedQueue<Throwable>()
    val previous = Thread.getDefaultUncaughtExceptionHandler()
    Thread.setDefaultUncaughtExceptionHandler { thread, failure ->
        if (thread.name.startsWith("mouse.node.net")) raised.add(failure)
        else previous?.uncaughtException(thread, failure)
    }
    try {
        repeat(40) {
            val recorder = SocketRecorder()
            val table = NodeSockets(recorder.post, recorder.retain, recorder.release)
            val serverId = table.listen("127.0.0.1", 0, 511)
            recorder.has(serverId, "listening", timeoutMs = 2_000)
            val port = recorder.port(serverId, "listening")
            val peer = Socket()
            try {
                peer.connect(InetSocketAddress("127.0.0.1", port), 2_000)
                peer.getOutputStream().write("race".toByteArray())
                peer.getOutputStream().flush()
            } catch (_: IOException) {
                // The point is the teardown below, not this peer. A refused connect still leaves
                // the selector mid-pass on the accept it was handling.
            }
            table.closeAll()
            try {
                peer.close()
            } catch (_: IOException) {
            }
        }
        // A thread killed by its handler dies after `closeAll` has already returned.
        Thread.sleep(300)
        checkEqual(
            raised.map { it::class.java.simpleName }.distinct().sorted().joinToString(",").ifEmpty { "none" },
            "none",
            "closeAll() under live traffic raises nothing on the selector thread",
        )
    } finally {
        Thread.setDefaultUncaughtExceptionHandler(previous)
    }
}

/**
 * The two cases that matter most: a REAL node client against our server, and our client against a
 * REAL node server.
 *
 * "It works when both ends are ours" proves nothing about the wire. These are the socket-table
 * equivalents of `verify/net`'s two cross-engine sections.
 */
private fun crossEngineCorpus(node: String?, table: NodeSockets, recorder: SocketRecorder) {
    if (node == null) {
        println("  SKIP: no `node` — the cross-engine socket checks need one")
        return
    }
    val scratch = Files.createTempDirectory("socketcross").toFile()
    try {
        // 1. Our server, node's client.
        val serverId = table.listen("127.0.0.1", 0, 511)
        if (!recorder.has(serverId, "listening")) {
            check(false, "the cross-engine server bound")
            return
        }
        val port = recorder.port(serverId, "listening")
        val client = File(scratch, "client.js")
        client.writeText(
            """
            const net = require('net');
            const socket = net.connect(Number(process.argv[2]), '127.0.0.1');
            let seen = '';
            socket.on('connect', () => socket.write('HELLO'));
            socket.on('data', (chunk) => { seen += chunk.toString(); });
            socket.on('end', () => { console.log('client saw: ' + JSON.stringify(seen)); });
            socket.on('error', (e) => console.log('client error: ' + e.code));
            """.trimIndent(),
        )
        // Reply and half-close from the accepted socket the moment its bytes arrive.
        Thread {
            if (recorder.has(serverId, "connection", timeoutMs = 10_000)) {
                val accepted = recorder.acceptedId(serverId)
                if (accepted != null && recorder.has(accepted, "data", timeoutMs = 10_000)) {
                    table.write(accepted, "ACK:${recorder.data(accepted)}".toByteArray())
                    table.end(accepted)
                }
            }
        }.also { it.isDaemon = true }.start()
        val (status, text) = run(listOf(node, client.path, port.toString()), scratch, 30)
        checkEqual(
            text.trim(), """client saw: "ACK:HELLO"""",
            "a real node CLIENT cannot tell our server from node's (exit $status)",
        )
        table.destroy(serverId)

        // 2. Node's server, our client. Node prints its port so nothing has to guess one.
        val server = File(scratch, "server.js")
        server.writeText(
            """
            const net = require('net');
            const server = net.createServer((socket) => {
              socket.on('data', (chunk) => socket.end('ACK:' + chunk.toString()));
            });
            server.listen(0, '127.0.0.1', () => {
              console.log('PORT ' + server.address().port);
            });
            setTimeout(() => process.exit(0), 20000).unref();
            """.trimIndent(),
        )
        val process = ProcessBuilder(node, server.path).directory(scratch)
            .redirectErrorStream(true).start()
        try {
            val reader = process.inputStream.bufferedReader()
            val line = reader.readLine()
            val nodePort = line?.removePrefix("PORT ")?.trim()?.toIntOrNull()
            if (nodePort == null) {
                check(false, "the real node server announced its port (said: $line)")
            } else {
                val id = table.connect("127.0.0.1", nodePort)
                check(recorder.has(id, "connect", timeoutMs = 10_000), "our client reached a real node server")
                table.write(id, "HELLO".toByteArray())
                check(recorder.has(id, "end", timeoutMs = 10_000), "node's server half-closed after answering")
                checkEqual(
                    recorder.data(id), "ACK:HELLO",
                    "a real node SERVER cannot tell our client from node's",
                )
                table.end(id)
                check(recorder.has(id, "close", timeoutMs = 10_000), "and our socket closes cleanly")
            }
        } finally {
            process.destroyForcibly()
        }
    } finally {
        scratch.deleteRecursively()
    }
}

// ----------------------------------------------------------------------- dns ----

/**
 * `NodeDns` — the wire format, and then the answers, against real node's own resolvers.
 *
 * The parse half is graded against a message built HERE, byte by byte, with compression pointers
 * in it. That is not a convenience: `res_9_dn_expand` is what the iOS side uses and no JVM has an
 * equivalent, so name expansion is the one piece of this file with no reference implementation to
 * lean on — and a plain byte scan reads a compressed name as garbage without ever failing.
 *
 * The live half is `verify/dnsres`'s own record types, asked of a real nameserver and compared with
 * real node asking for the same thing. It skips rather than fails when there is no resolver or no
 * network: a gate that goes red on a train is a gate nobody reads.
 */
private fun dnsCorpus(node: String?, scratch: File) {
    val dns = NodeDns { _, _, _ -> }
    try {
        checkEqual(dns.typeNumber("MX").toString(), "15", "record types carry their wire numbers")
        checkEqual(dns.typeNumber("CAA").toString(), "257", "including the ones past a byte")
        check(dns.typeNumber("DNSKEY") == null, "an unsupported type answers null — the bootstrap's ENOTIMP")

        checkEqual(
            dns.reverseName("8.8.8.8") ?: "<null>", "8.8.8.8.in-addr.arpa",
            "dns.reverse builds the in-addr.arpa name",
        )
        checkEqual(
            dns.reverseName("::1") ?: "<null>",
            "1.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.ip6.arpa",
            "and the ip6.arpa nibble form",
        )
        check(dns.reverseName("not-an-address") == null, "a hostname is not an address — EINVAL, not a wrong lookup")
        check(dns.reverseName("999.1.1.1") == null, "and neither is an out-of-range quad")
        checkEqual(dns.serviceName(443), "https", "lookupService names a well-known port")
        checkEqual(dns.serviceName(64999), "64999", "and answers the number for one with no name")

        // A response with A, CNAME (behind a pointer), MX, TXT and SOA records, hand-built so the
        // expected shapes are known exactly.
        val message = dnsAnswer()
        val a = dns.parse(message, 1)
        checkEqual(a.size.toString(), "1", "the parser finds the A record")
        checkEqual(a.firstOrNull()?.get("value").toString(), "93.184.216.34", "and reads its address")
        checkEqual(a.firstOrNull()?.get("ttl").toString(), "3600", "and its ttl")
        val mx = dns.parse(message, 15)
        checkEqual(mx.firstOrNull()?.get("priority").toString(), "10", "MX carries its priority")
        checkEqual(
            mx.firstOrNull()?.get("exchange").toString(), "mail.example.com",
            "and expands its exchange through a COMPRESSION POINTER — a plain byte scan reads this as garbage",
        )
        val txt = dns.parse(message, 16)
        @Suppress("UNCHECKED_CAST")
        checkEqual(
            (txt.firstOrNull()?.get("chunks") as? List<String>)?.joinToString("|") ?: "<none>",
            "v=spf1|-all",
            "TXT keeps its chunks SEPARATE — DKIM and SPF records rely on it",
        )
        val cname = dns.parse(message, 5)
        checkEqual(cname.firstOrNull()?.get("value").toString(), "example.com", "CNAME is a single name")
        val soa = dns.parse(message, 6)
        checkEqual(soa.firstOrNull()?.get("nsname").toString(), "ns.example.com", "SOA names its primary")
        checkEqual(soa.firstOrNull()?.get("refresh").toString(), "7200", "and its refresh interval")
        check(dns.parse(message, 33).isEmpty(), "a type the answer does not carry yields nothing")
        check(dns.parse(ByteArray(4), 1).isEmpty(), "a truncated message yields nothing rather than throwing")

        liveDnsCorpus(node, scratch)
    } finally {
        dns.close()
    }
}

/**
 * One DNS response, assembled here: two questions' worth of header, then five answers, with the
 * MX exchange and the SOA names written as COMPRESSION POINTERS back into the message. That is the
 * shape a real answer has and the reason `expand` exists.
 */
private fun dnsAnswer(): ByteArray {
    val out = java.io.ByteArrayOutputStream()
    fun u16(value: Int) { out.write(value shr 8); out.write(value and 0xff) }
    fun u32(value: Long) {
        out.write((value shr 24).toInt() and 0xff); out.write((value shr 16).toInt() and 0xff)
        out.write((value shr 8).toInt() and 0xff); out.write(value.toInt() and 0xff)
    }
    fun name(vararg labels: String) {
        for (label in labels) { out.write(label.length); out.write(label.toByteArray()) }
        out.write(0)
    }
    u16(0x1234); u16(0x8180); u16(1); u16(5); u16(0); u16(0)
    val questionAt = out.size()          // 12 — where "example.com" begins
    name("example", "com"); u16(255); u16(1)

    fun record(type: Int, ttl: Long, body: ByteArray) {
        out.write(0xc0); out.write(questionAt)       // the owner name, by pointer
        u16(type); u16(1); u32(ttl); u16(body.size); out.write(body)
    }
    record(1, 3600, byteArrayOf(93.toByte(), 184.toByte(), 216.toByte(), 34))
    record(5, 300, ByteArray(2) { if (it == 0) 0xc0.toByte() else questionAt.toByte() })

    // MX: priority, then "mail" followed by a pointer to "example.com" — the compressed form.
    val mx = java.io.ByteArrayOutputStream()
    mx.write(0); mx.write(10)
    mx.write(4); mx.write("mail".toByteArray()); mx.write(0xc0); mx.write(questionAt)
    record(15, 900, mx.toByteArray())

    val txt = java.io.ByteArrayOutputStream()
    txt.write(6); txt.write("v=spf1".toByteArray())
    txt.write(4); txt.write("-all".toByteArray())
    record(16, 60, txt.toByteArray())

    val soa = java.io.ByteArrayOutputStream()
    soa.write(2); soa.write("ns".toByteArray()); soa.write(0xc0); soa.write(questionAt)
    soa.write(9); soa.write("hostmaster".toByteArray().copyOf(9)); soa.write(0xc0); soa.write(questionAt)
    for (value in listOf(2024L, 7200L, 3600L, 604800L, 300L)) {
        soa.write((value shr 24).toInt() and 0xff); soa.write((value shr 16).toInt() and 0xff)
        soa.write((value shr 8).toInt() and 0xff); soa.write(value.toInt() and 0xff)
    }
    record(6, 1800, soa.toByteArray())
    return out.toByteArray()
}

/** The live half: our resolver's answers against real node's, for the same names. */
private fun liveDnsCorpus(node: String?, scratch: File) {
    if (node == null) {
        println("  SKIP: no `node` — the live DNS cross-check needs one")
        return
    }
    val answers = HashMap<String, String>()
    val latch = java.util.concurrent.CountDownLatch(4)
    val live = NodeDns { id, argsJson, _ ->
        answers[id.toString()] = argsJson
        latch.countDown()
    }
    if (live.servers.isEmpty()) {
        println("  SKIP: no nameserver in /etc/resolv.conf — the live DNS cross-check needs one")
        live.close()
        return
    }
    // Names chosen for the same reason `verify/dnsres` chose them: stable, publicly documented,
    // and answered the same way by every resolver.
    live.resolve(1, "example.com", "TXT")
    live.resolve(2, "gmail.com", "MX")
    live.resolve(3, "example.com", "NS")
    live.resolve(4, "this-name-does-not-exist-mouse.invalid", "TXT")
    if (!latch.await(30, TimeUnit.SECONDS)) {
        println("  SKIP: the network did not answer within 30s — the live DNS cross-check needs it")
        live.close()
        return
    }
    live.close()

    val probe = File(scratch, "dnsprobe.js")
    probe.writeText(
        """
        const dns = require('dns');
        const [, , kind] = process.argv;
        const done = (value) => { console.log(value); process.exit(0); };
        if (kind === 'txt') dns.resolveTxt('example.com', (e, r) => done(e ? 'err' : JSON.stringify(r.map(c => c.join('')).sort())));
        if (kind === 'mx') dns.resolveMx('gmail.com', (e, r) => done(e ? 'err' : JSON.stringify(r.map(x => x.priority + ':' + x.exchange).sort())));
        if (kind === 'ns') dns.resolveNs('example.com', (e, r) => done(e ? 'err' : JSON.stringify(r.sort())));
        """.trimIndent(),
    )

    fun ours(id: Int, shape: (Map<*, *>) -> String): String {
        val parsed = Json.parse(answers[id.toString()] ?: "[]") as? List<*> ?: return "<none>"
        val records = parsed.firstOrNull() as? List<*> ?: return "<none>"
        if ((parsed.getOrNull(1) as? String).orEmpty().isNotEmpty()) return "err"
        return records.mapNotNull { (it as? Map<*, *>)?.let(shape) }.sorted().let {
            "[" + it.joinToString(",") { entry -> "\"$entry\"" } + "]"
        }
    }

    val cases = listOf(
        Triple("txt", 1, { record: Map<*, *> ->
            @Suppress("UNCHECKED_CAST")
            (record["chunks"] as? List<String>).orEmpty().joinToString("")
        }),
        Triple("mx", 2, { record: Map<*, *> -> "${record["priority"]}:${record["exchange"]}" }),
        Triple("ns", 3, { record: Map<*, *> -> record["value"].toString() }),
    )
    for ((kind, id, shape) in cases) {
        val (status, text) = run(listOf(node, probe.path, kind), scratch, 30)
        if (status != 0 || text.trim() == "err") {
            println("  SKIP: real node could not resolve $kind — the live DNS cross-check needs the network")
            continue
        }
        checkEqual(ours(id, shape), text.trim(), "dns.resolve$kind agrees with real node for the same name")
    }
    // A name that does not exist must SAY so. The bootstrap turns the code into node's error, and
    // an empty list where a code belongs reads as "no records" — a different fact entirely.
    val missing = Json.parse(answers["4"] ?: "[]") as? List<*>
    check(
        (missing?.getOrNull(1) as? String).orEmpty().isNotEmpty(),
        "a name that does not exist reports a CODE, not an empty list",
    )
}

// ---------------------------------------------------------------------- http ----

/**
 * `NodeHttp` against a real node HTTP server.
 *
 * The head must be reported BEFORE the body — that is the whole difference between this transport
 * and a buffering one, and AGENTS.md records that a fixture comparing only the concatenated body
 * passes just as happily against a transport that buffers everything. So the ORDER of the events
 * is what is asserted, not only their contents.
 */
private fun httpCorpus(node: String?, scratch: File) {
    if (node == null) {
        println("  SKIP: no `node` — the HTTP transport check needs a server to talk to")
        return
    }
    val server = File(scratch, "httpserver.js")
    server.writeText(
        """
        const http = require('http');
        const server = http.createServer((request, response) => {
          let body = '';
          request.on('data', (c) => { body += c; });
          request.on('end', () => {
            if (request.url === '/slow') {
              response.writeHead(200, { 'Content-Type': 'text/plain' });
              response.write('one');
              setTimeout(() => response.end('two'), 150);
              return;
            }
            if (request.url === '/missing') { response.writeHead(404); response.end('nope'); return; }
            response.writeHead(201, { 'X-Made': 'thing', 'Content-Type': 'text/plain' });
            response.end('got:' + request.method + ':' + body);
          });
        });
        server.listen(0, '127.0.0.1', () => console.log('PORT ' + server.address().port));
        setTimeout(() => process.exit(0), 30000).unref();
        """.trimIndent(),
    )
    val process = ProcessBuilder(node, server.path).directory(scratch).redirectErrorStream(true).start()
    try {
        val line = process.inputStream.bufferedReader().readLine()
        val port = line?.removePrefix("PORT ")?.trim()?.toIntOrNull()
        if (port == null) {
            check(false, "the real node HTTP server announced its port (said: $line)")
            return
        }
        val events = java.util.Collections.synchronizedList(ArrayList<Pair<String, String>>())
        val done = java.util.concurrent.CountDownLatch(3)
        val http = NodeHttp(
            post = { id, argsJson, final ->
                events.add(id.toString() to argsJson)
                if (final) done.countDown()
            },
            retain = {}, release = {},
        )
        http.request(1, "http://127.0.0.1:$port/thing", "POST", """{"X-Try":"1"}""", base64("payload"))
        http.stream(2, "http://127.0.0.1:$port/slow", "GET", "{}", "")
        http.request(3, "http://127.0.0.1:$port/missing", "GET", "{}", "")
        check(done.await(30, TimeUnit.SECONDS), "every HTTP request settled within 30s")
        http.close()

        val whole = Json.parse(events.first { it.first == "1" }.second) as? List<*>
        val answer = whole?.firstOrNull() as? Map<*, *>
        checkEqual(answer?.get("status").toString(), "201", "httpRequest reports the status")
        checkEqual(
            String(Base64.getDecoder().decode(answer?.get("body") as? String ?: ""), Charsets.UTF_8),
            "got:POST:payload", "and carries the request body through and the response body back",
        )
        @Suppress("UNCHECKED_CAST")
        val headers = answer?.get("headers") as? Map<String, String>
        checkEqual(headers?.get("x-made") ?: "<absent>", "thing", "response headers arrive, lowercased as node reports them")

        val streamed = events.filter { it.first == "2" }.map {
            ((Json.parse(it.second) as? List<*>)?.firstOrNull() as? String).orEmpty()
        }
        checkEqual(
            streamed.joinToString(","), "head,data,data,end",
            "httpStream reports the HEAD first and each chunk as it arrives — a buffering " +
                "transport would report head,data,end and look identical in the body",
        )
        val body = events.filter { it.first == "2" }
            .mapNotNull { (Json.parse(it.second) as? List<*>) }
            .filter { it.firstOrNull() == "data" }
            .joinToString("") { String(Base64.getDecoder().decode(it[1] as String), Charsets.UTF_8) }
        checkEqual(body, "onetwo", "and the streamed chunks reassemble to the whole body")

        val notFound = (Json.parse(events.first { it.first == "3" }.second) as? List<*>)
            ?.firstOrNull() as? Map<*, *>
        checkEqual(notFound?.get("status").toString(), "404", "a 404 is an answer, not a failure")
        checkEqual(
            String(Base64.getDecoder().decode(notFound?.get("body") as? String ?: ""), Charsets.UTF_8),
            "nope", "and its body arrives — node's fetch resolves a 404 with its content",
        )
    } finally {
        process.destroyForcibly()
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

/**
 * Run a command and collect its output.
 *
 * The output is drained on its OWN thread and the wait is bounded. Reading the stream inline
 * looks equivalent and is not: `readText()` returns at EOF, which for a child that hangs never
 * comes — so a socket the child forgot to close turned a 120-second timeout into an indefinite
 * one, and the harness looked hung rather than failing. AGENTS.md: a hang is a worse bug than an
 * error. A child that overruns is killed and reports a non-zero status with whatever it managed
 * to say.
 */
private fun run(command: List<String>, directory: File, timeoutSeconds: Long = 120): Pair<Int, String> {
    val process = ProcessBuilder(command).directory(directory).redirectErrorStream(true).start()
    val collected = StringBuilder()
    val reader = Thread {
        try {
            process.inputStream.bufferedReader().forEachLine { collected.appendLine(it) }
        } catch (_: Exception) {
        }
    }
    reader.isDaemon = true
    reader.start()
    val finished = process.waitFor(timeoutSeconds, TimeUnit.SECONDS)
    if (!finished) {
        process.destroyForcibly()
        process.waitFor(5, TimeUnit.SECONDS)
        reader.join(2_000)
        return -1 to (collected.toString() + "\n[killed after ${timeoutSeconds}s]")
    }
    reader.join(5_000)
    return process.exitValue() to collected.toString()
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

    // 3c's: net, http, dns and dgram through the shim, the job queue and the bootstrap's own
    // modules. The SAME program the device gate runs — which is what makes an on-device MISMATCH
    // mean the WebView rather than the corpus.
    val socketRun = runSmoke(
        node, bootstrap, scratch, "sockets",
        NodeSocketSmoke.CONFIG.globalsScript(), NodeSocketSmoke.PROGRAM, NodeSocketSmoke.ENTRY_PATH,
    )
    if (socketRun != null) {
        val socketFailures = NodeSocketSmoke.grade(socketRun.stdout, socketRun.stderr, socketRun.exit)
        checks += NodeSocketSmoke.CHECK_COUNT
        failures += socketFailures.size
        for (failure in socketFailures) println("  FAIL: $failure")
    }

    fsParityCorpus(node, bootstrap, scratch)
    netFixtureCorpus(node, bootstrap, scratch)
}

/**
 * `verify/neterrors` and `verify/reqsock`, run through the Android bridge and graded against the
 * SAME checked-in `node.txt` iOS is graded against.
 *
 * Read straight out of `verify/` rather than copied, exactly as `:screencheck` reads its corpus and
 * as `fsParityCorpus` reads `verify/fsparity`. A fixture that has been copied is a fixture that can
 * drift, and a parity claim gated against a different file from the one the other platform is
 * gated against is unfalsifiable.
 *
 * What these prove that [NodeSocketSmoke] does not is the ERROR family and the socket's reported
 * STATE: EADDRINUSE from a second listen, `HPE_INVALID_METHOD` from a request that is not HTTP, an
 * idle `setTimeout` firing, the 400 a bad request gets when nobody is listening for `clientError`,
 * ECONNREFUSED — and `socket.server`, `bufferSize`, `localFamily`, `resetAndDestroy` reading back
 * what node reports for the same socket.
 */
private fun netFixtureCorpus(node: String, bootstrap: String, scratch: File) {
    // reqsock compares by LABEL, neterrors by position — each fixture's own rule, kept.
    val cases = listOf(
        Triple("neterrors", "probe.js", false),
        Triple("reqsock", "probe.js", true),
    )
    for ((name, scriptName, byLabel) in cases) {
        val script = File(repoRoot, "verify/$name/$scriptName")
        val expectedFile = File(repoRoot, "verify/$name/node.txt")
        check(script.exists() && expectedFile.exists(), "verify/$name is where the harness reads it from")
        if (!script.exists() || !expectedFile.exists()) continue

        val run = runSmoke(
            node, bootstrap, scratch, name,
            NodeProcessConfig(argv = listOf("node", "/probe.js"), cwd = "/").globalsScript(),
            script.readText(), "/probe.js",
        ) ?: continue

        val expected = expectedFile.readText().trim().lines().filter { it.isNotBlank() }
        val ours = run.stdout.trim().lines().filter { it.isNotBlank() }
        var wrong = 0
        if (byLabel) {
            // reqsock keys on the text before the first ": " — extra lines on our side are
            // ignored and a missing label reports itself, which is the harness's own rule.
            val mine = ours.associate { it.substringBefore(": ") to it.substringAfter(": ", "") }
            for (line in expected) {
                val label = line.substringBefore(": ")
                val want = line.substringAfter(": ", "")
                val got = mine[label]
                if (got != want) {
                    wrong += 1
                    println("  FAIL: $name [$label]\n      node: $want\n      ours: ${got ?: "<missing>"}")
                }
            }
        } else {
            for (i in 0 until maxOf(expected.size, ours.size)) {
                val want = expected.getOrNull(i) ?: "<missing>"
                val got = ours.getOrNull(i) ?: "<missing>"
                if (want != got) {
                    wrong += 1
                    println("  FAIL: $name line ${i + 1}\n      node: $want\n      ours: $got")
                }
            }
        }
        checks += expected.size
        failures += wrong
    }
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
    const realSetTimeout = setTimeout;

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
    let jobs = [];                  // [handlerId, argsJson, final] — the iOS enqueueJob queue
    let exitCode = null;
    let holds = 0, stdinActive = false;
    let stdout = '', stderr = '';

    // A REAL clock, not a virtual one. The driver stands in for NodeWebView, and NodeWebView runs
    // on a Handler with wall time under it; the socket half cannot be driven any other way, because
    // its events arrive from the OS when the OS decides. A virtual clock that jumped to the next
    // due time would fire a program's watchdog before its first packet had left.
    const started = Date.now();
    const now = () => Date.now() - started;

    // Every completion the host hands back — socket events, DNS answers, HTTP chunks. Kotlin frames
    // these with HostBridge.job; the shape is the contract and it is spelled the same here.
    const postJob = (handlerId, args, final) => {
      jobs.push([handlerId, JSON.stringify(args), final ? 1 : 0]);
    };

    globalThis.__mouseHost = {
      asset: (name) => fs.readFileSync(name, 'utf8'),
      stdout: (text) => { stdout += text; },
      stderr: (text) => { stderr += text; },
      exit: (code) => { if (exitCode === null) exitCode = code; },
      monotonicNanos: () => realProcess.hrtime.bigint().toString(),
      setTimer: (delay, repeat) => {
        const id = nextId++;
        const ms = Math.max(1, delay);
        timers.set(id, { due: now() + ms, interval: repeat ? ms : null, refed: true });
        return id;
      },
      clearTimer: (id) => { timers.delete(id); },
      timerRef: (id, refed) => { const t = timers.get(id); if (t) t.refed = refed; },
      timerRefresh: (id) => { const t = timers.get(id); if (t) t.due = now() + (t.interval || 1); },
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
      loopUtilization: () => JSON.stringify({ idle: now(), active: 0 }),
      setRawMode: () => {},

      // ---- sockets, dns and the TLS transport ----
      //
      // Real node's own `net`, `dns`, `dgram` and `https`, exactly as the filesystem half of this
      // stand-in is real node's own `fs`. That is deliberate and it is the same disposition
      // milestone 3b took for the module loader: the thing under test here is `node-host.js` and
      // the bootstrap above it — the marshalling, the handler registry, the job queue, the `net`
      // and `http` modules — and grading those against a JavaScript re-implementation of
      // `NodeSockets` would prove nothing about either. The KOTLIN table is graded separately and
      // more strictly, against real node PEERS on a real wire (`socketsCorpus`). The two meet for
      // the first time on a device.
      netConnect: (host, port) => openSocket(realNet.connect({ host, port, allowHalfOpen: true })),
      netListen: (host, port, backlog) => openServer(host, port, backlog),
      netWrite: (id, base64) => {
        const entry = handles.get(id);
        if (!entry || entry.closed) return true;
        return entry.socket.write(Buffer.from(base64, 'base64'));
      },
      netEnd: (id) => { const e = handles.get(id); if (e && !e.closed) e.socket.end(); },
      netDestroy: (id) => {
        const e = handles.get(id);
        if (!e || e.closed) return;
        // Three kinds of handle answer to one bridge name, as they do in the Kotlin table: a
        // listening server, a stream socket, and a datagram socket — `dgram`'s close() lands here
        // too, which is what the first version of this stand-in missed.
        if (e.server) {
          try { e.server.close(); } catch (err) {}
          retire(id);
          postJob(id, [id, 'close', null], lastForOwner(id, id));
        } else if (e.datagram) {
          try { e.datagram.close(); } catch (err) { retire(id); postJob(id, [id, 'close', null], lastForOwner(id, id)); }
        } else {
          e.socket.destroy();
        }
      },
      netPause: (id) => { const e = handles.get(id); if (e && e.socket) e.socket.pause(); },
      netResume: (id) => { const e = handles.get(id); if (e && e.socket) e.socket.resume(); },
      netRef: (id, refed) => {
        const e = handles.get(id);
        if (!e || e.refed === refed) return;
        e.refed = refed;
        holds += refed ? 1 : -1;
        const handle = e.server || e.socket;
        if (handle) { if (refed) handle.ref(); else handle.unref(); }
      },
      netNoDelay: (id, on) => { const e = handles.get(id); if (e && e.socket && e.socket.setNoDelay) e.socket.setNoDelay(on); },
      netKeepAlive: (id, on, delay) => { const e = handles.get(id); if (e && e.socket && e.socket.setKeepAlive) e.socket.setKeepAlive(on, delay); },
      netResolve: (host, family) => {
        const id = nextId++;
        holds += 1;
        realDns.lookup(host, { all: true, family: family || 0 }, (error, found) => {
          const list = (found || []).map((entry) => ({ address: entry.address, family: entry.family }));
          postJob(id, [list, list.length ? '' : 'ENOTFOUND'], true);
          holds -= 1;
        });
        return id;
      },

      // The dns.resolve* family. `dnsDone` gives the handle back, so it is taken by the QUERY —
      // the iOS `pendingLookups` pair, and the bootstrap calls it exactly once per answer.
      dnsResolve: (name, type) => resolveRecords(name, type),
      dnsReverse: (address) => {
        const id = nextId++;
        holds += 1;
        realDns.reverse(address, (error, names) => {
          postJob(id, [names || [], error ? (error.code || 'ENOTFOUND') : ''], true);
        });
        return id;
      },
      dnsService: (address, port) => {
        const id = nextId++;
        holds += 1;
        realDns.lookupService(address, port, (error, host, service) => {
          postJob(id, [host || '', service || '', error ? (error.code || 'ENOTFOUND') : ''], true);
        });
        return id;
      },
      dnsDone: () => { holds -= 1; },

      httpRequest: (url, method, headersJson, bodyBase64) => transport(url, method, headersJson, bodyBase64, false),
      httpStream: (url, method, headersJson, bodyBase64) => transport(url, method, headersJson, bodyBase64, true),

      dgramBind: (host, port, broadcast) => bindDatagram(host, port, broadcast),
      dgramSend: (id, base64, host, port) => {
        const cb = nextId++;
        const entry = handles.get(id);
        if (!entry || !entry.datagram) { postJob(cb, ['EBADF'], true); return cb; }
        entry.datagram.send(Buffer.from(base64, 'base64'), port, host, (error) => {
          postJob(cb, [error ? (error.code || 'EBADF') : ''], true);
        });
        return cb;
      },
      dgramMembership: (id, group, iface, join) => {
        const entry = handles.get(id);
        if (!entry || !entry.datagram) return 'EBADF';
        try {
          if (join) entry.datagram.addMembership(group, iface || undefined);
          else entry.datagram.dropMembership(group, iface || undefined);
          return '';
        } catch (e) { return e.code || 'EINVAL'; }
      },
      dgramOption: (id, ttl, loopback, iface) => {
        const entry = handles.get(id);
        if (!entry || !entry.datagram) return;
        try {
          if (ttl >= 0) entry.datagram.setMulticastTTL(ttl);
          if (loopback >= 0) entry.datagram.setMulticastLoopback(loopback === 1);
          if (iface) entry.datagram.setMulticastInterface(iface);
        } catch (e) {}
      },
    };

    // ---- the socket stand-in's own bookkeeping ----
    const realNet = require('net');
    const realDns = require('dns');
    const realDgram = require('dgram');
    const realHttp = require('http');
    const realHttps = require('https');
    const { URL: RealURL } = require('url');

    const handles = new Map();   // id -> { socket|server|datagram, ownerId, refed, closed }

    const place = (address) => ({
      address: (address && address.address) || '',
      port: (address && address.port) || 0,
      family: (address && String(address.family).indexOf('6') >= 0) ? 'IPv6' : 'IPv4',
    });

    function retire(id) {
      const entry = handles.get(id);
      if (!entry || entry.closed) return;
      entry.closed = true;
      handles.delete(id);
      if (entry.refed) holds -= 1;
    }

    // A handler may be dropped only when the OWNER and every socket routed through it are gone.
    // `server.close()` retires the listener while its connections are still finishing, so
    // "this entry is its own owner" is not enough — dropping there loses their remaining events,
    // and a `server.close(cb)` whose callback never fires is the symptom. Same rule as
    // NodeSockets.teardown; this stand-in has to keep it or it would grade a different contract.
    function lastForOwner(id, ownerId) {
      if (id !== ownerId && handles.has(ownerId)) return false;
      for (const entry of handles.values()) if (entry.ownerId === ownerId) return false;
      return true;
    }

    // Every event of a socket goes to the handler its OWNER was registered under, which for an
    // accepted socket is the SERVER's — the rule that closes the window where a connection exists
    // with nothing listening for it. `final` is true only for the owner's own close.
    function wire(id, ownerId, socket) {
      socket.on('data', (chunk) => postJob(ownerId, [id, 'data', chunk.toString('base64')], false));
      socket.on('end', () => postJob(ownerId, [id, 'end', null], false));
      socket.on('drain', () => postJob(ownerId, [id, 'drain', null], false));
      socket.on('error', (e) => postJob(ownerId, [id, 'error', { message: e.message, code: e.code || 'ECONNRESET' }], false));
      socket.on('close', () => {
        retire(id);
        postJob(ownerId, [id, 'close', null], lastForOwner(id, ownerId));
      });
    }

    function openSocket(socket) {
      const id = nextId++;
      holds += 1;
      handles.set(id, { socket, ownerId: id, refed: true, closed: false });
      socket.on('connect', () => postJob(id, [id, 'connect', {
        local: place({ address: socket.localAddress, port: socket.localPort, family: socket.localFamily }),
        remote: place({ address: socket.remoteAddress, port: socket.remotePort, family: socket.remoteFamily }),
      }], false));
      wire(id, id, socket);
      return id;
    }

    function openServer(host, port, backlog) {
      const id = nextId++;
      holds += 1;
      const server = realNet.createServer({ allowHalfOpen: true });
      handles.set(id, { server, ownerId: id, refed: true, closed: false });
      server.on('listening', () => postJob(id, [id, 'listening', place(server.address())], false));
      server.on('error', (e) => {
        postJob(id, [id, 'error', { message: e.message, code: e.code || 'EADDRINUSE' }], false);
        retire(id);
        postJob(id, [id, 'close', null], lastForOwner(id, id));
      });
      server.on('connection', (socket) => {
        const accepted = nextId++;
        holds += 1;
        handles.set(accepted, { socket, ownerId: id, refed: true, closed: false });
        wire(accepted, id, socket);
        postJob(id, [id, 'connection', {
          id: accepted,
          local: place({ address: socket.localAddress, port: socket.localPort, family: socket.localFamily }),
          remote: place({ address: socket.remoteAddress, port: socket.remotePort, family: socket.remoteFamily }),
        }], false);
      });
      server.listen(port, host || '0.0.0.0', backlog || 511);
      return id;
    }

    function bindDatagram(host, port, broadcast) {
      const id = nextId++;
      holds += 1;
      const datagram = realDgram.createSocket({ type: 'udp4', reuseAddr: true });
      handles.set(id, { datagram, ownerId: id, refed: true, closed: false });
      datagram.on('listening', () => {
        if (broadcast) { try { datagram.setBroadcast(true); } catch (e) {} }
        postJob(id, [id, 'listening', place(datagram.address())], false);
      });
      datagram.on('message', (message, from) => postJob(id, [id, 'datagram', {
        data: message.toString('base64'), from: place(from),
      }], false));
      datagram.on('error', (e) => postJob(id, [id, 'error', { message: e.message, code: e.code || 'EBADF' }], false));
      datagram.on('close', () => { retire(id); postJob(id, [id, 'close', null], lastForOwner(id, id)); });
      datagram.bind(port, host || '0.0.0.0');
      return id;
    }

    function resolveRecords(name, type) {
      const id = nextId++;
      const method = 'resolve' + type;
      if (typeof realDns[method] !== 'function') { postJob(id, [[], 'ENOTIMP'], true); return id; }
      realDns[method](name, (error, records) => {
        if (error) { postJob(id, [[], error.code || 'ENOTFOUND'], true); return; }
        postJob(id, [reshape(type, records), ''], true);
      });
      return id;
    }

    // node's dns module hands back its PUBLIC shapes; the bridge contract is the RAW record shape
    // the iOS host produces, which the bootstrap then reshapes into the public one. So this turns
    // node's answers back into raw records — the inverse of what the bootstrap does, which is what
    // makes the round trip through the bootstrap a real test of it.
    function reshape(type, records) {
      if (type === 'Txt') return records.map((chunks) => ({ chunks }));
      if (type === 'Ns' || type === 'Cname' || type === 'Ptr') return records.map((value) => ({ value }));
      if (type === 'Soa') return [records];
      if (type === 'Caa') return records.map((entry) => {
        const tag = Object.keys(entry).filter((k) => k !== 'critical')[0];
        return { critical: entry.critical, tag, value: entry[tag] };
      });
      if (type === 'Tlsa') return records.map((r) => ({
        certUsage: r.certUsage, selector: r.selector, match: r.match,
        data: Array.from(new Uint8Array(r.data || new ArrayBuffer(0))),
      }));
      return records;
    }

    function transport(urlText, method, headersJson, bodyBase64, streaming) {
      const id = nextId++;
      holds += 1;
      let target;
      try { target = new RealURL(urlText); }
      catch (e) {
        postJob(id, streaming ? ['error', 'invalid URL: ' + urlText] : [{ error: 'invalid URL: ' + urlText }], true);
        holds -= 1;
        return id;
      }
      const client = target.protocol === 'https:' ? realHttps : realHttp;
      const body = bodyBase64 ? Buffer.from(bodyBase64, 'base64') : null;
      const request = client.request(urlText, {
        method: method || 'GET',
        headers: JSON.parse(headersJson || '{}'),
      }, (response) => {
        const headers = {};
        for (const key of Object.keys(response.headers)) headers[key] = String(response.headers[key]);
        const chunks = [];
        if (streaming) postJob(id, ['head', { status: response.statusCode, headers }], false);
        response.on('data', (chunk) => {
          if (streaming) postJob(id, ['data', chunk.toString('base64')], false);
          else chunks.push(chunk);
        });
        response.on('end', () => {
          if (streaming) postJob(id, ['end', null], true);
          else postJob(id, [{ status: response.statusCode, headers, body: Buffer.concat(chunks).toString('base64') }], true);
          holds -= 1;
        });
      });
      request.on('error', (e) => {
        postJob(id, streaming ? ['error', e.message] : [{ error: e.message }], true);
        holds -= 1;
      });
      if (body) request.write(body);
      request.end();
      return id;
    }

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
    // JOBS FIRST, then immediates, then the earliest due timer. That is `runEventLoop`'s own
    // sequence and `NodeWebView.pump`'s: an I/O completion outranks work that was merely
    // scheduled, which is what makes a socket's data reach its handler ahead of a timer set after
    // it. Both queues are snapshotted before they run — anything queued DURING a batch belongs to
    // the next turn, or timers starve forever.
    const parked = { until: 0 };
    const turn = () => {
      if (exitCode !== null) return false;
      if (jobs.length) {
        const batch = jobs;
        jobs = [];
        globalThis.__mouseDispatch.jobs(batch);
        return true;
      }
      if (immediates.length) {
        const batch = immediates;
        immediates = [];
        globalThis.__mouseDispatch.immediates(batch);
        return true;
      }
      let due = null;
      for (const [id, t] of timers) {
        if (t.due <= now() && (due === null || t.due < timers.get(due).due)) due = id;
      }
      if (due !== null) {
        const t = timers.get(due);
        if (t.interval !== null) t.due = now() + t.interval; else timers.delete(due);
        globalThis.__mouseDispatch.timer(due);
        return true;
      }
      const quiet = holds === 0 && !stdinActive && ![...timers.values()].some((t) => t.refed);
      if (quiet) return false;
      // Not quiet, nothing ready: PARK. `holds` here is an open socket or an in-flight lookup, and
      // the answer arrives when the OS says so — the branch the iOS loop spends in
      // `wakeup.wait(timeout: .now() + 60)`. Waiting a real millisecond is what lets node's own
      // event loop run and deliver it.
      let soonest = null;
      for (const t of timers.values()) if (soonest === null || t.due < soonest) soonest = t.due;
      parked.until = soonest === null ? now() + 2 : Math.min(soonest, now() + 20);
      return true;
    };

    // A REAL macrotask between turns. Each turn is one evaluateJavascript call on Android, and the
    // microtask checkpoint that runs as it ends is half of the tick discipline — a driver that
    // spun synchronously would never let a promise reaction run and would grade the ordering
    // wrong, in the engine's favour.
    const yieldTurn = () => new Promise((resolve) => realSetImmediate(resolve));
    const realSleep = (ms) => new Promise((resolve) => realSetTimeout(resolve, ms));

    (async () => {
      const result = JSON.parse(globalThis.__mouseDispatch.entry(
        fs.readFileSync('program.js', 'utf8'), fs.readFileSync('entry-path.txt', 'utf8').trim()));
      if (!result.ok) fs.writeFileSync('entry-error.txt', String(result.error));
      // Bounded by WALL TIME rather than turn count: with real sockets a turn can be a park, and a
      // program waiting on the network legitimately takes thousands of them.
      while (Date.now() - started < 90000) {
        parked.until = 0;
        await yieldTurn();
        if (!turn()) break;
        if (parked.until > now()) await realSleep(Math.max(1, parked.until - now()));
      }
      globalThis.__mouseDispatch.finish();
      fs.writeFileSync('out.txt', stdout);
      fs.writeFileSync('err.txt', stderr);
      fs.writeFileSync('exit.txt', String(exitCode));
      // Close every handle the stand-in opened and LEAVE. This is `SocketTable.closeAll()` — a
      // program that forgot its server must not outlive itself — and here it is also what lets the
      // process end at all: node's own loop stays awake for a listening socket, so without this
      // the driver finishes its work and then hangs forever with nothing to do, which the harness
      // reading its stdout would wait on indefinitely.
      for (const entry of handles.values()) {
        try { (entry.server || entry.socket || entry.datagram).destroy ? (entry.server || entry.socket || entry.datagram).destroy() : (entry.server || entry.datagram).close(); }
        catch (e) {}
      }
      realProcess.exit(0);
    })();
""".trimIndent()


// -------------------------------------------------------------------------- main ----------

/** `--keep-scratch`: do not delete the smokes' directories, so a failure can be read afterwards. */
private var keepScratch = false

fun main(args: Array<String>) {
    keepScratch = args.contains("--keep-scratch")
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
        socketsCorpus(node)
        dnsCorpus(node, scratch)
        httpCorpus(node, scratch)
        nodeCorpus(bootstrap, scratch)
    } finally {
        // `--args=--keep-scratch` leaves the smoke's directories in place. A smoke that fails is
        // graded on files it wrote (out.txt, err.txt, entry-error.txt) and deleting them is
        // deleting the evidence — the same reason `verify/unixsock` leaves its temp dir on
        // failure.
        if (!keepScratch) scratch.deleteRecursively() else println("  scratch kept at ${scratch.path}")
    }

    if (failures == 0) {
        println(
            "NODE LAYER: $checks checks — bootstrap drift vs swift/Mouse/NodeEngine.swift, bridge " +
                "partition, process globals, event loop, cpu time, filesystem and module " +
                "resolution vs real node, sockets vs real node peers on a real wire, the DNS wire " +
                "format and resolvers vs real node, the TLS transport's streaming, node --check, " +
                "load smoke, verify/fsparity, verify/neterrors, verify/reqsock — MATCH",
        )
    } else {
        println("NODE LAYER: $failures of $checks checks failed — MISMATCH")
        exitProcess(1)
    }
}
