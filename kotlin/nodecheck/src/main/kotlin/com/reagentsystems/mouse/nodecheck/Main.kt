package com.reagentsystems.mouse.nodecheck

import com.reagentsystems.mouse.node.Bootstrap
import com.reagentsystems.mouse.node.HostBridge
import com.reagentsystems.mouse.node.ModuleResolver
import com.reagentsystems.mouse.node.NodeCpu
import com.reagentsystems.mouse.node.NodeFs
import com.reagentsystems.mouse.node.NodeFsSmoke
import com.reagentsystems.mouse.node.NodeLoop
import com.reagentsystems.mouse.node.EsmTranspiler
import com.reagentsystems.mouse.node.NodeCrypto
import com.reagentsystems.mouse.node.NodeDns
import com.reagentsystems.mouse.node.NodeHttp
import com.reagentsystems.mouse.node.NodeKeys
import com.reagentsystems.mouse.node.NodeProcessConfig
import com.reagentsystems.mouse.node.NodeSmoke
import com.reagentsystems.mouse.node.NodeSocketSmoke
import com.reagentsystems.mouse.node.NodeSockets
import com.reagentsystems.mouse.node.NodeZlib
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
    File(scratch, "platform.js").writeText(
        Bootstrap.platformScript("android", "Linux", "arm64", "16"),
    )
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
    // The host tells the engine which machine it is on, AFTER the bootstrap has hardcoded
    // Darwin. NodeWebView does exactly this; the driver does it from the same function with the
    // same arguments, so the two hosts cannot answer differently and NodeSmoke can assert it.
    error = globalThis.__mouseEval(fs.readFileSync('platform.js', 'utf8'), 'platform.js');
    if (error) die('platform: ' + error);

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
        cryptoCorpus(node, scratch)
        rewriteImportsCorpus()
        zlibCorpus(node, scratch)
        cipherCorpus(node, scratch)
        keyIdentifyCorpus(node, scratch)
        keySignCorpus(node, scratch)
        keyAgreeCorpus(node, scratch)
        rsaCipherCorpus(node, scratch)
        esmCorpus(node, scratch)
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
                "format and resolvers vs real node, the TLS transport's streaming, key identity " +
                "across PKCS#8/SEC1/PKCS#1/SPKI vs real node, EC/RSA/Ed25519 signing graded both " +
                "directions against real node, key generation real node can use, ECDH agreeing " +
                "with node's own half, RSA-PSS, node --check, " +
                "load smoke, verify/fsparity, verify/neterrors, verify/reqsock — MATCH",
        )
    } else {
        println("NODE LAYER: $failures of $checks checks failed — MISMATCH")
        exitProcess(1)
    }
}

// ---------------------------------------------------------------------------- ESM ----

/**
 * One ES module case: a little package, and what real node prints when it runs it.
 *
 * The grammar is enumerated rather than trusted, for the reason `verify/esmgrammar` gives on the
 * iOS side and which these cases are taken from: a transpiler that works by pattern is only as
 * good as its enumeration, and two holes in iOS's were found by accident because dual packages
 * kept resolving to their CommonJS half.
 */
private class EsmCase(val name: String, val files: Map<String, String>)

private val ESM_CASES: List<EsmCase> = listOf(
    EsmCase(
        "export-declarations",
        mapOf(
            "dep.mjs" to """
                export const constant = 'const';
                export let mutable = 'let';
                export var older = 'var';
                export function plain() { return 'function'; }
                export async function waited() { return 'async function'; }
                export function* generated() { yield 'function*'; }
                export async function* streamed() { yield 'async function*'; }
                export class Named { get who() { return 'class'; } }
            """.trimIndent(),
            "main.mjs" to """
                import * as dep from './dep.mjs';
                console.log(dep.constant, dep.mutable, dep.older);
                console.log(dep.plain());
                console.log(dep.generated().next().value);
                console.log(new dep.Named().who);
            """.trimIndent(),
        ),
    ),
    EsmCase(
        "default-and-named",
        mapOf(
            "dep.mjs" to """
                const value = 'the-default';
                export default value;
                export const extra = 'extra';
            """.trimIndent(),
            "main.mjs" to """
                import value, { extra } from './dep.mjs';
                console.log(value, extra);
            """.trimIndent(),
        ),
    ),
    EsmCase(
        "aliases-and-clause",
        mapOf(
            "dep.mjs" to """
                const a = 1, b = 2;
                export { a, b as renamed };
            """.trimIndent(),
            "main.mjs" to """
                import { a, renamed as alias } from './dep.mjs';
                console.log(a, alias);
            """.trimIndent(),
        ),
    ),
    EsmCase(
        "re-export-star",
        mapOf(
            "base.mjs" to "export const one = 1;\nexport const two = 2;\nexport default 'base-default';",
            "dep.mjs" to "export * from './base.mjs';\nexport const three = 3;",
            "main.mjs" to """
                import * as dep from './dep.mjs';
                console.log(dep.one, dep.two, dep.three);
                console.log(dep.default);
            """.trimIndent(),
        ),
    ),
    EsmCase(
        "export-default-function",
        mapOf(
            "dep.mjs" to "export default function named() { return 'from-default-fn'; }",
            "main.mjs" to "import fn from './dep.mjs';\nconsole.log(fn());",
        ),
    ),
    EsmCase(
        "strings-are-not-code",
        mapOf(
            // The mask's whole reason: this line is DATA. A blind rewrite corrupts it and then
            // assigns a binding that does not exist.
            // The embedded statement starts a LINE, which is the only way it reaches the
            // statement patterns' `^` anchor — a string on the same line as its assignment
            // never could, so a case written that way exercises nothing. This is vite's
            // worker shim in the shape it actually ships.
            "main.mjs" to "const shim = `\nexport default function WorkerWrapper(options) {}\n`;\n" +
                "export const kept = shim.trim().length;\n" +
                "console.log(shim.trim());\nconsole.log(kept);",
        ),
    ),
    EsmCase(
        "dynamic-import",
        mapOf(
            "dep.mjs" to "export default 'lazy';",
            "main.mjs" to "const m = await import('./dep.mjs');\nconsole.log(m.default);",
        ),
    ),
)

/**
 * The transpiler, graded against REAL NODE running the same package as real ES modules.
 *
 * This cannot go through [DRIVER] the way the filesystem corpus does. That stand-in host is
 * JavaScript, the transpiler is Kotlin, and a JS copy of it in the harness would be grading our
 * loader against a second copy of our own beliefs — the thing this suite refuses to do
 * everywhere else. So the reference is node itself: it runs `main.mjs` as ESM, we transpile the
 * same files to CommonJS, node runs THAT, and the two stdouts must be identical.
 *
 * The little loader below is harness scaffolding, not a second implementation: it does what
 * `node-host.js` does — wrap in an async function with the same seven parameters — because the
 * transpiled source emits top-level `await` and has to be given somewhere to do it.
 */
private fun esmCorpus(node: String?, parent: File) {
    if (node == null) {
        check(true, "ESM corpus skipped — no real node to grade against")
        return
    }
    for (case in ESM_CASES) {
        val real = File(parent, "esm-real-${case.name}").also { it.deleteRecursively(); it.mkdirs() }
        for ((name, text) in case.files) File(real, name).writeText(text)
        val (realStatus, realOut) = run(listOf(node, "main.mjs"), real)
        if (realStatus != 0) {
            check(false, "real node runs ${case.name} as ESM:\n${realOut.take(600)}")
            continue
        }

        val ours = File(parent, "esm-ours-${case.name}").also { it.deleteRecursively(); it.mkdirs() }
        for ((name, text) in case.files) {
            File(ours, name).writeText(EsmTranspiler.transpile(text))
        }
        File(ours, "run.cjs").writeText(ESM_RUNNER)
        val (ourStatus, ourOut) = run(listOf(node, "run.cjs"), ours)
        if (ourStatus != 0) {
            check(false, "the transpiled ${case.name} runs:\n${ourOut.take(900)}")
            continue
        }
        checkEqual(ourOut.trimEnd(), realOut.trimEnd(), "ESM ${case.name} matches real node")
    }
}

/**
 * What `node-host.js` does, in the harness: wrap a transpiled module in an ASYNC function with
 * the same seven parameters, and answer a promise of its exports so an importer's
 * `if (x instanceof Promise) x = await x` has something to await. The four runtime helpers are
 * the shared bootstrap's, restated here only because a bare `node` has no bootstrap.
 */
private val ESM_RUNNER = """
    const fs = require('fs');
    const path = require('path');
    const cache = {};

    function __esmDefault(m) {
      if (m && typeof m === 'object' && '__esModule' in m) return m.default;
      return (m && typeof m === 'object' && 'default' in m) ? m.default : m;
    }
    function __esmBinding(m, name) { return m[name]; }
    function __mouseLive(target, name, get) {
      Object.defineProperty(target, name, { get: get, enumerable: true, configurable: true });
    }
    function __reexportStar(target, source) {
      for (const key of Object.keys(source || {})) {
        if (key === 'default' || key === '__esModule') continue;
        Object.defineProperty(target, key, {
          get: () => source[key], enumerable: true, configurable: true,
        });
      }
    }
    function __dynamicImport(req, spec) { return Promise.resolve(req(spec)); }

    function load(id) {
      if (id in cache) return cache[id];
      const source = fs.readFileSync(id, 'utf8');
      const dir = path.dirname(id);
      const require_ = (spec) => spec.startsWith('.') ? load(path.resolve(dir, spec)) : require(spec);
      const fn = eval('(async function (exports, require, module, __filename, __dirname, __mouseRequire, __mouseFilename) {'
        + source + '\n})');
      const module_ = { exports: {} };
      const settled = fn(module_.exports, require_, module_, id, dir, require_, id)
        .then(() => { cache[id] = module_.exports; return module_.exports; });
      cache[id] = settled;
      return settled;
    }

    load(path.resolve('main.mjs')).catch((e) => {
      console.error((e && e.stack) || e);
      process.exitCode = 1;
    });
""".trimIndent()

// ------------------------------------------------------------------------- crypto ----

/**
 * Digests, HMACs and PBKDF2, graded against REAL NODE computing the same thing.
 *
 * The point of asking node rather than pinning hex strings: a pinned vector proves the algorithm
 * was implemented, not that OUR spelling of it reaches the same function. `sha224` exists in the
 * JCA and not in CryptoKit; node's HMAC names have no separator and its digest names do; an empty
 * HMAC key is legal to node and rejected by the JCA. Every one of those is a translation error
 * waiting to happen, and every one of them shows up as a different digest.
 */
private fun cryptoCorpus(node: String?, parent: File) {
    if (node == null) {
        check(true, "crypto corpus skipped — no real node to grade against")
        return
    }
    val scratch = File(parent, "crypto").also { it.mkdirs() }
    val messages = listOf("", "a", "hello world", "the quick brown fox\n", "\u00ff\u00fe binary-ish")
    val digests = listOf("md5", "sha1", "sha224", "sha256", "sha384", "sha512")
    val keys = listOf("", "k", "a longer key than one block of sha512 ".repeat(4))

    // One node run for the whole corpus: a process per digest would dominate the wall clock.
    val plan = StringBuilder()
    plan.append("const crypto = require('crypto');\nconst out = [];\n")
    for (message in messages) {
        val m = Json.write(message)
        for (digest in digests) {
            plan.append("out.push(crypto.createHash(${Json.write(digest)})")
                .append(".update(Buffer.from($m,'utf8')).digest('base64'));\n")
        }
    }
    for (key in keys) {
        val k = Json.write(key)
        for (digest in digests) {
            plan.append("out.push(crypto.createHmac(${Json.write(digest)}, Buffer.from($k,'utf8'))")
                .append(".update(Buffer.from('hello world','utf8')).digest('base64'));\n")
        }
    }
    for (digest in listOf("md5", "sha1", "sha256", "sha512")) {
        plan.append("out.push(crypto.pbkdf2Sync(Buffer.from('password','utf8'),")
            .append("Buffer.from('salt','utf8'),1000,32,${Json.write(digest)}).toString('base64'));\n")
    }
    // PASSWORDS THAT ARE NOT ASCII. Every case above is, and that is exactly why the old
    // `PBEKeySpec` route passed the corpus while disagreeing with node for any byte over 0x7f:
    // the JDK encodes those chars as UTF-8, not latin-1. An accented passphrase is ordinary input.
    for (password in listOf("[255,254,65]", "[0]", "[]", "[195,169,110]")) {
        plan.append("out.push(crypto.pbkdf2Sync(Buffer.from($password),")
            .append("Buffer.from('salt','utf8'),1000,32,'sha256').toString('base64'));\n")
    }
    // And a key length that is not a whole number of blocks, which exercises the block loop.
    plan.append("out.push(crypto.pbkdf2Sync(Buffer.from('password','utf8'),")
        .append("Buffer.from('salt','utf8'),17,70,'sha256').toString('base64'));\n")
    plan.append("console.log(out.join('\\n'));\n")
    File(scratch, "plan.js").writeText(plan.toString())
    val (status, text) = run(listOf(node, "plan.js"), scratch)
    if (status != 0) {
        check(false, "real node computed the crypto corpus:\n${text.take(600)}")
        return
    }
    val expected = text.trim().lines()

    val ours = ArrayList<String>()
    val label = ArrayList<String>()
    val b64 = { value: String -> Base64.getEncoder().encodeToString(value.toByteArray(Charsets.UTF_8)) }
    for (message in messages) {
        for (digest in digests) {
            ours.add(NodeCrypto.hash(digest, b64(message)) ?: "<null>")
            label.add("$digest of ${message.length} bytes")
        }
    }
    for (key in keys) {
        for (digest in digests) {
            ours.add(NodeCrypto.hmac(digest, b64(key), b64("hello world")) ?: "<null>")
            label.add("hmac-$digest with a ${key.length}-byte key")
        }
    }
    for (digest in listOf("md5", "sha1", "sha256", "sha512")) {
        ours.add(NodeCrypto.pbkdf2(b64("password"), b64("salt"), 1000, 32, digest) ?: "<null>")
        label.add("pbkdf2-$digest, 1000 rounds, 32 bytes")
    }
    for ((name, bytes) in listOf(
        "a high-byte password" to byteArrayOf(-1, -2, 65),
        "a NUL password" to byteArrayOf(0),
        "an EMPTY password" to ByteArray(0),
        "a UTF-8 accented password" to byteArrayOf(-61, -87, 110),
    )) {
        ours.add(
            NodeCrypto.pbkdf2(
                Base64.getEncoder().encodeToString(bytes), b64("salt"), 1000, 32, "sha256",
            ) ?: "<null>",
        )
        label.add("pbkdf2 with $name")
    }
    ours.add(NodeCrypto.pbkdf2(b64("password"), b64("salt"), 17, 70, "sha256") ?: "<null>")
    label.add("pbkdf2 over a partial final block — 70 bytes")

    checkEqual(ours.size.toString(), expected.size.toString(), "the crypto corpus lines up with node's")
    if (ours.size != expected.size) return
    for (i in ours.indices) checkEqual(ours[i], expected[i], "crypto: ${label[i]}")

    // ---- the two KDFs the JCA has no factory for ----
    //
    // Both are DETERMINISTIC, so this asks for the strongest thing available: byte-identical
    // output, not a round trip. A KDF that round-trips through itself proves nothing at all, since
    // there is nothing to trip against — its whole job is to agree with the other implementations
    // of the same RFC.
    val kdfPlan = StringBuilder("const crypto = require('crypto');\nconst out = [];\n")
    val hkdfCases = listOf(
        // digest, key, salt, info, length. The empty salt is RFC 5869's own default and reaches
        // the zero-length-key branch in the HMAC underneath.
        listOf("sha256", "key material", "salt", "info", "32"),
        listOf("sha256", "k", "", "", "42"),
        listOf("sha1", "key material", "salt", "context", "20"),
        listOf("sha512", "key material", "salt", "context", "128"),
        // Longer than one block, to exercise the counter and the final partial block.
        listOf("sha256", "key material", "salt", "info", "100"),
    )
    for (case in hkdfCases) {
        kdfPlan.append("out.push(crypto.hkdfSync(${Json.write(case[0])},")
            .append("Buffer.from(${Json.write(case[1])},'utf8'),")
            .append("Buffer.from(${Json.write(case[2])},'utf8'),")
            .append("Buffer.from(${Json.write(case[3])},'utf8'),${case[4]}));\n")
    }
    kdfPlan.append("out.forEach((v,i)=>{out[i]=Buffer.from(v).toString('base64')});\n")
    val scryptCases = listOf(
        // password, salt, N, r, p, length. RFC 7914's own vectors are among these.
        listOf("password", "NaCl", "1024", "8", "16", "64"),
        listOf("", "", "16", "1", "1", "64"),
        listOf("pleaseletmein", "SodiumChloride", "16384", "8", "1", "64"),
        // p > 1 is the case that exercises ROMix being applied per block rather than once.
        listOf("secret", "salt", "256", "4", "3", "48"),
    )
    for (case in scryptCases) {
        kdfPlan.append("out.push(crypto.scryptSync(Buffer.from(${Json.write(case[0])},'utf8'),")
            .append("Buffer.from(${Json.write(case[1])},'utf8'),${case[5]},")
            .append("{N:${case[2]},r:${case[3]},p:${case[4]},maxmem:512*1024*1024})")
            .append(".toString('base64'));\n")
    }
    kdfPlan.append("console.log(out.join('\\n'));\n")
    File(scratch, "kdf.js").writeText(kdfPlan.toString())
    val (kdfStatus, kdfText) = run(listOf(node, "kdf.js"), scratch)
    if (kdfStatus != 0) {
        check(false, "real node computed the KDF corpus:\n${kdfText.take(600)}")
    } else {
        val expectedKdf = kdfText.trim().lines()
        val ourKdf = ArrayList<Pair<String, String>>()
        for (case in hkdfCases) {
            ourKdf.add(
                (NodeCrypto.hkdf(case[0], b64(case[1]), b64(case[2]), b64(case[3]), case[4].toInt())
                    ?: "<null>") to "hkdf-${case[0]}, ${case[4]} bytes, info ${case[3].length} long",
            )
        }
        for (case in scryptCases) {
            ourKdf.add(
                (NodeCrypto.scrypt(
                    b64(case[0]), b64(case[1]),
                    case[2].toInt(), case[3].toInt(), case[4].toInt(), case[5].toInt(),
                ) ?: "<null>") to "scrypt N=${case[2]} r=${case[3]} p=${case[4]}, ${case[5]} bytes",
            )
        }
        checkEqual(
            ourKdf.size.toString(), expectedKdf.size.toString(),
            "the KDF corpus lines up with node's",
        )
        if (ourKdf.size == expectedKdf.size) {
            for (i in ourKdf.indices) checkEqual(ourKdf[i].first, expectedKdf[i], ourKdf[i].second)
        }
        // Parameters scrypt is not defined for must refuse, not approximate. N must be a power of
        // two above 1 because ROMix indexes its table with `mod N`.
        check(NodeCrypto.scrypt(b64("p"), b64("s"), 1000, 8, 1, 32) == null, "scrypt refuses N=1000, not a power of two")
        check(NodeCrypto.scrypt(b64("p"), b64("s"), 1, 8, 1, 32) == null, "scrypt refuses N=1")
        check(NodeCrypto.scrypt(b64("p"), b64("s"), 16, 0, 1, 32) == null, "scrypt refuses r=0")
        check(NodeCrypto.hkdf("sha3-256", b64("k"), b64("s"), b64("i"), 32) == null, "hkdf refuses a digest with no Mac")
        // RFC 5869 caps expansion at 255 blocks because the counter is one byte.
        check(NodeCrypto.hkdf("sha256", b64("k"), b64("s"), b64("i"), 255 * 32 + 1) == null, "hkdf refuses beyond 255 blocks")
    }

    // An algorithm we do not know must answer NULL, because that is what the bootstrap branches on
    // to raise node's own error. Answering an empty string would be a wrong digest, not a refusal.
    check(NodeCrypto.hash("sha3-256", b64("x")) == null, "an unknown digest answers null, not a value")
    check(NodeCrypto.hmac("nope", b64("k"), b64("x")) == null, "an unknown HMAC answers null")
    check(NodeCrypto.pbkdf2(b64("p"), b64("s"), 1, 16, "sha3-256") == null, "pbkdf2 refuses a digest with no Mac")
    check(NodeCrypto.pbkdf2(b64("p"), b64("s"), 0, 16, "sha256") == null, "pbkdf2 refuses zero rounds")

    val uuid = NodeCrypto.randomUUID()
    check(
        Regex("^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$").matches(uuid),
        "randomUUID is a lower-case v4 UUID ($uuid)",
    )
    check(NodeCrypto.randomUUID() != uuid, "randomUUID does not repeat itself")
}

/**
 * `rewriteImports` — the code-only `import(…)` rewrite for source compiled at RUNTIME.
 *
 * Gated on its own rather than only through the ESM corpus, because its callers are different:
 * the loader rewrites a FILE, this rewrites a string a program built at runtime, and the thing
 * that must not differ between them is what they refuse to touch. A bundle carries JavaScript
 * inside string literals — that is the whole reason the rewriter is a scanner — and a runtime
 * compile is exactly where such a string ends up.
 */
private fun rewriteImportsCorpus() {
    checkEqual(
        EsmTranspiler.rewriteDynamicImport("const m = await import('./x.js');"),
        "const m = await __dynamicImport(__mouseRequire, './x.js');",
        "rewriteImports rewrites a dynamic import",
    )
    val inString = "const s = \"await import('./x.js')\";"
    checkEqual(
        EsmTranspiler.rewriteDynamicImport(inString),
        inString,
        "rewriteImports leaves an import inside a STRING alone",
    )
    val inComment = "// import('./x.js')\nconst a = 1;"
    checkEqual(
        EsmTranspiler.rewriteDynamicImport(inComment),
        inComment,
        "rewriteImports leaves an import inside a COMMENT alone",
    )
    checkEqual(
        EsmTranspiler.rewriteDynamicImport("obj.import('./x.js');"),
        "obj.import('./x.js');",
        "rewriteImports leaves a METHOD named import alone",
    )
    checkEqual(
        EsmTranspiler.rewriteDynamicImport("const plain = 1;"),
        "const plain = 1;",
        "rewriteImports returns source with no import untouched",
    )
}

// --------------------------------------------------------------------------- zlib ----

/**
 * Compression, graded BOTH DIRECTIONS against real node.
 *
 * One direction is not enough and the reason is the framing. `java.util.zip` gives DEFLATE and
 * nothing else, so gzip's header, its CRC32/ISIZE trailer and the gzip-or-zlib auto-detect are
 * written by hand here — and a codec that is wrong in a self-consistent way round-trips through
 * ITSELF perfectly while producing bytes no other implementation accepts. So node decompresses
 * what we compress, and we decompress what node compressed.
 */
/**
 * `NodeKeys.identify` against real node, over keys real node GENERATED.
 *
 * The reference supplies both halves here, which is what makes this differential rather than a
 * table someone typed: node emits each key in every encoding it supports, and node also states
 * what it thinks each one is (`asymmetricKeyType`, `namedCurve`, `modulusLength`). Reading the
 * algorithm OID has to reach the same verdict from the bytes alone.
 *
 * The encodings are the point. The same EC key is a different DER grammar as PKCS#8, as SEC1, and
 * as SPKI, and RSA's PKCS#1 forms carry no algorithm identifier at all — the label is the only
 * thing that says RSA. A parser that only ever saw `PRIVATE KEY` would pass a corpus that only
 * generated `PRIVATE KEY`.
 */
private fun keyIdentifyCorpus(node: String?, parent: File) {
    if (node == null) {
        check(true, "key identity corpus skipped — no real node to grade against")
        return
    }
    val scratch = File(parent, "keys").also { it.mkdirs() }
    val plan = StringBuilder()
    plan.append(
        """
        const crypto = require('crypto');
        const out = [];
        // name | node's own verdict | base64 of the PEM. node is the reference for BOTH the key
        // and the answer, so a wrong expectation cannot be written down here by hand.
        function record(name, pem) {
          const key = pem.includes('PUBLIC KEY')
            ? crypto.createPublicKey(pem) : crypto.createPrivateKey(pem);
          const details = key.asymmetricKeyDetails || {};
          const verdict = key.asymmetricKeyType + '|' + (details.namedCurve || '') +
                          '|' + (details.modulusLength || 0);
          out.push(name + '\t' + verdict + '\t' + Buffer.from(pem, 'utf8').toString('base64'));
        }
        function pair(name, type, options, privateType) {
          const keys = crypto.generateKeyPairSync(type, Object.assign({
            publicKeyEncoding: { type: 'spki', format: 'pem' },
            privateKeyEncoding: { type: privateType, format: 'pem' },
          }, options));
          record(name + ' private (' + privateType + ')', keys.privateKey);
          record(name + ' public (spki)', keys.publicKey);
        }
        for (const curve of ['prime256v1', 'secp384r1', 'secp521r1']) {
          pair('ec ' + curve, 'ec', { namedCurve: curve }, 'pkcs8');
          pair('ec ' + curve, 'ec', { namedCurve: curve }, 'sec1');
        }
        for (const type of ['ed25519', 'ed448', 'x25519', 'x448']) {
          pair(type, type, {}, 'pkcs8');
        }
        for (const bits of [2048, 3072]) {
          pair('rsa ' + bits, 'rsa', { modulusLength: bits }, 'pkcs8');
          pair('rsa ' + bits, 'rsa', { modulusLength: bits }, 'pkcs1');
        }
        // PKCS#1 public form: SEQ { INT n, INT e }, with no algorithm identifier anywhere.
        const rsa = crypto.generateKeyPairSync('rsa', {
          modulusLength: 2048,
          publicKeyEncoding: { type: 'pkcs1', format: 'pem' },
          privateKeyEncoding: { type: 'pkcs8', format: 'pem' },
        });
        record('rsa 2048 public (pkcs1)', rsa.publicKey);
        console.log(out.join('\n'));
        """.trimIndent(),
    )
    File(scratch, "plan.js").writeText(plan.toString())
    val (status, text) = run(listOf(node, "plan.js"), scratch)
    if (status != 0) {
        check(false, "real node generated the key corpus:\n${text.take(600)}")
        return
    }

    var rows = 0
    for (line in text.trim().lines()) {
        val parts = line.split("\t")
        if (parts.size != 3) continue
        rows += 1
        val (name, verdict, pemBase64) = parts
        val pem = String(Base64.getDecoder().decode(pemBase64), Charsets.UTF_8)
        val identity = NodeKeys.identify(pem)
        val ours = "${identity.type}|${identity.curve}|${identity.modulusLength}"
        checkEqual(ours, verdict, "key identity: $name")
    }
    // 12 EC (3 curves × {pkcs8, sec1} × {private, public}) + 8 edwards/montgomery + 8 RSA
    // (2 sizes × {pkcs8, pkcs1} × {private, public}) + 1 PKCS#1 public.
    check(rows == 29, "the key corpus produced every encoding — $rows rows, expected 29")

    // Curves node supports and this does not must answer `unknown`, NOT a wrong curve. The
    // bootstrap turns `unknown` into node's ERR_CRYPTO_INVALID_KEY_OBJECT_TYPE, and its message
    // names P-256/384/521; answering a nearby curve would sign with the wrong one instead.
    val exotic = File(scratch, "exotic.js")
    exotic.writeText(
        "const crypto = require('crypto');\n" +
            "const k = crypto.generateKeyPairSync('ec', { namedCurve: 'secp256k1', " +
            "publicKeyEncoding: { type: 'spki', format: 'pem' }, " +
            "privateKeyEncoding: { type: 'pkcs8', format: 'pem' } });\n" +
            "process.stdout.write(k.privateKey);\n",
    )
    val (exoticStatus, secp256k1) = run(listOf(node, "exotic.js"), scratch)
    if (exoticStatus == 0) {
        checkEqual(
            NodeKeys.identify(secp256k1).type,
            "unknown",
            "a curve this does not support is unknown, not a nearby curve",
        )
    }

    // Malformed input answers `unknown` rather than throwing: every caller is asking a question,
    // and an exception here would escape through a bridge method that promises a value.
    for ((label, bad) in listOf(
        "empty text" to "",
        "no PEM block" to "just some words",
        "a truncated body" to "-----BEGIN PUBLIC KEY-----\nMFkwEwYH\n-----END PUBLIC KEY-----",
        "base64 that is not DER" to "-----BEGIN PUBLIC KEY-----\naGVsbG8gd29ybGQ=\n-----END PUBLIC KEY-----",
        "mismatched labels" to "-----BEGIN PUBLIC KEY-----\naGVsbG8=\n-----END PRIVATE KEY-----",
    )) {
        checkEqual(NodeKeys.identify(bad).type, "unknown", "malformed key — $label — is unknown")
    }
}

/**
 * Signing and verifying against real node — BOTH DIRECTIONS, which is the only arrangement that
 * catches a self-consistent mistake.
 *
 * A signature scheme that is wrong in a stable way verifies its own output perfectly. So node signs
 * and this verifies; this signs and node verifies. Only the crossing checks agreement, and only the
 * crossing catches an encoding that is internally coherent and not what node produces — which is
 * exactly the failure mode `ieee-p1363` invites, since raw and DER signatures of the same key over
 * the same bytes are both "valid" to something that only ever talks to itself.
 *
 * ECDSA is randomised, so signatures cannot be compared byte for byte the way the cipher corpus
 * compares ciphertext. Verification is the equality that exists. RSA PKCS#1 v1.5 IS deterministic,
 * and is compared byte for byte as well, because for that scheme an identical signature is a
 * strictly stronger claim than a passing verify.
 */
private fun keySignCorpus(node: String?, parent: File) {
    if (node == null) {
        check(true, "key signing corpus skipped — no real node to grade against")
        return
    }
    val scratch = File(parent, "keysign").also { it.mkdirs() }
    val message = "the quick brown fox  with a NUL and ÿ a high byte"
    val messageBase64 = Base64.getEncoder().encodeToString(message.toByteArray(Charsets.UTF_8))

    // node generates the keys, signs the message with each, and reports what it produced. The
    // `raw` column is node's `dsaEncoding: 'ieee-p1363'`, the flat r||s form the JCA never emits.
    File(scratch, "plan.js").writeText(
        """
        const crypto = require('crypto');
        const message = Buffer.from(${Json.write(messageBase64)}, 'base64');
        const out = [];
        function emit(name, priv, pub, algorithm, dsaEncoding) {
          const options = dsaEncoding ? { key: priv, dsaEncoding } : priv;
          const signature = crypto.sign(algorithm, message, options);
          out.push([name, algorithm || '', dsaEncoding || '', Buffer.from(priv).toString('base64'),
                    Buffer.from(pub).toString('base64'), signature.toString('base64')].join('\t'));
        }
        for (const curve of ['prime256v1', 'secp384r1', 'secp521r1']) {
          const k = crypto.generateKeyPairSync('ec', { namedCurve: curve,
            publicKeyEncoding: { type: 'spki', format: 'pem' },
            privateKeyEncoding: { type: 'pkcs8', format: 'pem' } });
          for (const digest of ['sha1', 'sha256', 'sha384', 'sha512']) {
            emit('ec ' + curve, k.privateKey, k.publicKey, digest, null);
          }
          emit('ec ' + curve + ' p1363', k.privateKey, k.publicKey, 'sha256', 'ieee-p1363');
          // The same key as SEC1, so the wrapper this builds is exercised and not just PKCS#8.
          const sec1 = crypto.createPrivateKey(k.privateKey)
            .export({ type: 'sec1', format: 'pem' });
          emit('ec ' + curve + ' sec1', sec1, k.publicKey, 'sha256', null);
        }
        {
          const k = crypto.generateKeyPairSync('ed25519', {
            publicKeyEncoding: { type: 'spki', format: 'pem' },
            privateKeyEncoding: { type: 'pkcs8', format: 'pem' } });
          emit('ed25519', k.privateKey, k.publicKey, null, null);
        }
        for (const bits of [2048, 3072]) {
          const k = crypto.generateKeyPairSync('rsa', { modulusLength: bits,
            publicKeyEncoding: { type: 'spki', format: 'pem' },
            privateKeyEncoding: { type: 'pkcs8', format: 'pem' } });
          for (const digest of ['sha1', 'sha256', 'sha512']) {
            emit('rsa ' + bits, k.privateKey, k.publicKey, digest, null);
          }
          // PKCS#1 on both sides, so both re-wrappers are exercised.
          const p1 = crypto.createPrivateKey(k.privateKey).export({ type: 'pkcs1', format: 'pem' });
          const pub1 = crypto.createPublicKey(k.publicKey).export({ type: 'pkcs1', format: 'pem' });
          out.push(['rsa ' + bits + ' pkcs1', 'sha256', '', Buffer.from(p1).toString('base64'),
                    Buffer.from(pub1).toString('base64'),
                    crypto.sign('sha256', message, p1).toString('base64')].join('\t'));
        }
        console.log(out.join('\n'));
        """.trimIndent(),
    )
    val (status, text) = run(listOf(node, "plan.js"), scratch)
    if (status != 0) {
        check(false, "real node signed the corpus:\n${text.take(600)}")
        return
    }

    val rows = text.trim().lines().mapNotNull { line ->
        val parts = line.split("\t")
        if (parts.size == 6) parts else null
    }
    // 18 EC (3 curves × {4 digests, p1363, sec1}) + 1 ed25519 + 8 RSA (2 sizes × {3 digests, pkcs1}).
    check(rows.size == 27, "the signing corpus is complete — ${rows.size} rows, expected 27")

    val ours = ArrayList<String>()
    for (row in rows) {
        val name = row[0]
        val algorithm = row[1]
        val dsaEncoding = row[2]
        val publicBase64 = row[4]
        val expected = row[5]
        val privatePem = String(Base64.getDecoder().decode(row[3]), Charsets.UTF_8)
        val publicPem = String(Base64.getDecoder().decode(publicBase64), Charsets.UTF_8)
        val raw = dsaEncoding == "ieee-p1363"

        // node signed → this verifies. With the public key, and again with the private one,
        // because node accepts either and so must this.
        check(
            NodeKeys.verify(publicPem, messageBase64, expected, algorithm, raw),
            "node's signature verifies here — $name/$algorithm${if (raw) " p1363" else ""}",
        )
        // node accepts a PRIVATE key where a public one would do, and so does this — except for
        // Ed25519, where the public half cannot be recovered from the encoded seed without curve
        // arithmetic this deliberately does not implement. That divergence is asserted here rather
        // than left for someone to hit: if it is ever closed, this check fails and says so.
        val fromPrivate = NodeKeys.verify(privatePem, messageBase64, expected, algorithm, raw)
        if (name == "ed25519") {
            check(
                !fromPrivate,
                "ed25519 refuses to verify from a private key — recovering its public half needs " +
                    "a scalar multiplication the JCA does not expose",
            )
        } else {
            check(fromPrivate, "…and verifies against the private key too — $name/$algorithm")
        }

        // this signs → node verifies. Collected and handed over in one batch below.
        val mine = NodeKeys.sign(privatePem, messageBase64, algorithm, raw)
        check(mine != null, "this signs — $name/$algorithm${if (raw) " p1363" else ""}")
        ours.add(listOf(name, algorithm, dsaEncoding, publicBase64, mine ?: "").joinToString("\t"))

        // RSA PKCS#1 v1.5 is deterministic: the bytes themselves must match, not merely verify.
        if (name.startsWith("rsa")) {
            checkEqual(mine ?: "<null>", expected, "byte-identical to node's — $name/$algorithm")
        }
    }

    File(scratch, "ours.tsv").writeText(ours.joinToString("\n"))
    File(scratch, "verify.js").writeText(
        """
        const crypto = require('crypto');
        const fs = require('fs');
        const message = Buffer.from(${Json.write(messageBase64)}, 'base64');
        const out = [];
        for (const line of fs.readFileSync('ours.tsv', 'utf8').split('\n')) {
          if (!line.trim()) continue;
          const [name, algorithm, dsaEncoding, pub, signature] = line.split('\t');
          const pem = Buffer.from(pub, 'base64').toString('utf8');
          let ok = false;
          try {
            const key = dsaEncoding ? { key: pem, dsaEncoding } : pem;
            ok = crypto.verify(algorithm || null, message, key, Buffer.from(signature, 'base64'));
          } catch (e) { ok = false; }
          out.push(name + '/' + algorithm + (dsaEncoding ? ' p1363' : '') + '\t' + ok);
        }
        console.log(out.join('\n'));
        """.trimIndent(),
    )
    val (verifyStatus, verifyText) = run(listOf(node, "verify.js"), scratch)
    if (verifyStatus != 0) {
        check(false, "real node verified our signatures:\n${verifyText.take(600)}")
        return
    }
    var verified = 0
    for (line in verifyText.trim().lines()) {
        val parts = line.split("\t")
        if (parts.size != 2) continue
        verified += 1
        check(parts[1] == "true", "real node verifies our signature — ${parts[0]}")
    }
    check(verified == rows.size, "node graded every signature — $verified of ${rows.size}")

    // OPENSSL'S LEGACY NAMES. `crypto.createSign` takes an OpenSSL algorithm name, not a bare
    // digest, and real libraries use the long forms: `jwa` signs RS256 by asking for
    // `RSA-SHA256`. Every check above passes the digest node's short way — the way a hand-written
    // test does — so the corpus was green while `jsonwebtoken` failed on the device at the first
    // attempt. These are the spellings that were missing.
    val legacyRow = rows.first { it[0].startsWith("rsa 2048") && it[1] == "sha256" }
    val legacyPrivate = String(Base64.getDecoder().decode(legacyRow[3]), Charsets.UTF_8)
    val legacyPublic = String(Base64.getDecoder().decode(legacyRow[4]), Charsets.UTF_8)
    for (spelling in listOf("RSA-SHA256", "rsa-sha256", "SHA256", "sha256")) {
        val signature = NodeKeys.sign(legacyPrivate, messageBase64, spelling, false)
        checkEqual(
            signature ?: "<null>", legacyRow[5],
            "an RSA signature is the same under the name `$spelling`",
        )
        check(
            NodeKeys.verify(legacyPublic, messageBase64, legacyRow[5], spelling, false),
            "and verifies under `$spelling`",
        )
    }
    val ecRow = rows.first { it[0].startsWith("ec prime256v1") && it[1] == "sha256" && it[2].isEmpty() }
    val ecPublic = String(Base64.getDecoder().decode(ecRow[4]), Charsets.UTF_8)
    for (spelling in listOf("ecdsa-with-SHA256", "RSA-SHA256")) {
        // `RSA-SHA256` on an EC key is not a mistake: node's prefix is historical and applies to
        // any key type, which is exactly why the normaliser strips it rather than branching on it.
        check(
            NodeKeys.verify(ecPublic, messageBase64, ecRow[5], spelling, false),
            "an EC signature verifies under `$spelling` too",
        )
    }

    // A tampered message must NOT verify. Without this the whole corpus would pass against a
    // `verify` that returned true unconditionally.
    val tampered = Base64.getEncoder().encodeToString("a different message".toByteArray())
    val first = rows.first()
    check(
        !NodeKeys.verify(
            String(Base64.getDecoder().decode(first[4]), Charsets.UTF_8),
            tampered, first[5], first[1], false,
        ),
        "a signature over other bytes is refused",
    )
    check(
        !NodeKeys.verify(
            String(Base64.getDecoder().decode(first[4]), Charsets.UTF_8),
            messageBase64, Base64.getEncoder().encodeToString(ByteArray(16)), first[1], false,
        ),
        "a malformed signature is refused rather than thrown on",
    )
}

/**
 * Generation, ECDH and RSA-PSS — the three that cannot be graded by comparing bytes.
 *
 * A generated key is fresh every run and an ECDH exchange has two halves, so "identical to node's"
 * is not available. What IS available is the property each one actually has to satisfy:
 *
 *  - a generated key must be one REAL NODE CAN USE — so node imports it, signs with it, and this
 *    verifies. A key that parses here and nowhere else would pass a self-check.
 *  - a shared secret must MATCH THE OTHER SIDE'S — so node and this each generate a pair, exchange
 *    public halves, and both compute. Agreement is the whole property; a wrong-but-consistent
 *    implementation agrees with itself and not with node.
 *  - a PSS signature is randomised, so it is cross-verified in both directions like ECDSA.
 */
private fun keyAgreeCorpus(node: String?, parent: File) {
    if (node == null) {
        check(true, "key agreement corpus skipped — no real node to grade against")
        return
    }
    val scratch = File(parent, "keyagree").also { it.mkdirs() }
    val message = "agreement and generation"
    val messageBase64 = Base64.getEncoder().encodeToString(message.toByteArray(Charsets.UTF_8))

    // ---- generation: this generates, node uses ----
    val generated = ArrayList<String>()
    for (curve in listOf("prime256v1", "secp384r1", "secp521r1")) {
        val pair = NodeKeys.generate("ec", curve)
        check(pair != null, "generates an EC key on $curve")
        if (pair == null) continue
        val signature = NodeKeys.sign(pair.second, messageBase64, "sha256", false)
        check(signature != null, "signs with the key it just generated — $curve")
        generated.add(
            listOf(
                "ec $curve", "sha256",
                Base64.getEncoder().encodeToString(pair.first.toByteArray(Charsets.UTF_8)),
                signature ?: "",
            ).joinToString("\t"),
        )
    }
    for (kind in listOf("ed25519")) {
        val pair = NodeKeys.generate(kind, "")
        check(pair != null, "generates an $kind key")
        if (pair == null) continue
        val signature = NodeKeys.sign(pair.second, messageBase64, "", false)
        check(signature != null, "signs with the $kind key it just generated")
        generated.add(
            listOf(
                kind, "",
                Base64.getEncoder().encodeToString(pair.first.toByteArray(Charsets.UTF_8)),
                signature ?: "",
            ).joinToString("\t"),
        )
    }
    val rsa = NodeKeys.rsaGenerate(2048)
    check(rsa != null, "generates a 2048-bit RSA key")
    if (rsa != null) {
        checkEqual(
            NodeKeys.identify(rsa.second).modulusLength.toString(), "2048",
            "the generated RSA key reports the size it was asked for",
        )
        val signature = NodeKeys.sign(rsa.second, messageBase64, "sha256", false)
        generated.add(
            listOf(
                "rsa 2048", "sha256",
                Base64.getEncoder().encodeToString(rsa.first.toByteArray(Charsets.UTF_8)),
                signature ?: "",
            ).joinToString("\t"),
        )
        // PSS, cross-verified both ways.
        val pss = NodeKeys.rsaSign(rsa.second, messageBase64, "sha256", true)
        check(pss != null, "signs with RSA-PSS")
        check(
            NodeKeys.rsaVerify(rsa.first, messageBase64, pss ?: "", "sha256", true),
            "its own PSS signature verifies",
        )
        check(
            !NodeKeys.rsaVerify(rsa.first, messageBase64, pss ?: "", "sha256", false),
            "a PSS signature is NOT accepted as PKCS#1 v1.5 — the paddings are not interchangeable",
        )
        generated.add(
            listOf(
                "rsa 2048 pss", "sha256",
                Base64.getEncoder().encodeToString(rsa.first.toByteArray(Charsets.UTF_8)),
                pss ?: "",
            ).joinToString("\t"),
        )
    }
    File(scratch, "generated.tsv").writeText(generated.joinToString("\n"))

    // ---- ECDH: this generates one half, node the other, and the secrets must agree ----
    val exchanges = ArrayList<String>()
    for (curve in listOf("prime256v1", "secp384r1", "secp521r1")) {
        val mine = NodeKeys.ecdhGenerate(curve)
        check(mine != null, "generates an ECDH pair on $curve")
        if (mine != null) exchanges.add("$curve\t${mine.first}\t${mine.second}")
    }
    File(scratch, "exchanges.tsv").writeText(exchanges.joinToString("\n"))

    File(scratch, "check.js").writeText(
        """
        const crypto = require('crypto');
        const fs = require('fs');
        const message = Buffer.from(${Json.write(messageBase64)}, 'base64');
        const out = [];

        // Every key this generated must be usable by real node.
        for (const line of fs.readFileSync('generated.tsv', 'utf8').split('\n')) {
          if (!line.trim()) continue;
          const [name, algorithm, pub, signature] = line.split('\t');
          const pem = Buffer.from(pub, 'base64').toString('utf8');
          let ok = false;
          try {
            // The salt length is PINNED to the digest's, not left at node's verify-side default
            // of RSA_PSS_SALTLEN_AUTO. Auto accepts whatever salt the signature happens to carry,
            // so a cross-verify against it cannot see a wrong salt length at all — which is
            // exactly what a deliberate break proved when it sailed through unnoticed. Strict
            // verifiers (WebCrypto among them) do not auto-detect, so the length has to be right.
            const key = name.endsWith('pss')
              ? { key: pem, padding: crypto.constants.RSA_PKCS1_PSS_PADDING,
                  saltLength: crypto.constants.RSA_PSS_SALTLEN_DIGEST }
              : pem;
            ok = crypto.verify(algorithm || null, message, key,
                               Buffer.from(signature, 'base64'));
          } catch (e) { ok = false; }
          out.push('use\t' + name + '\t' + ok);
        }

        // ECDH: node takes our public half, we take node's, and the secrets must be equal.
        for (const line of fs.readFileSync('exchanges.tsv', 'utf8').split('\n')) {
          if (!line.trim()) continue;
          const [curve, , ourPublic] = line.split('\t');
          const theirs = crypto.createECDH(curve);
          const theirPublic = theirs.generateKeys();
          const secret = theirs.computeSecret(Buffer.from(ourPublic, 'base64'));
          out.push('ecdh\t' + curve + '\t' + theirPublic.toString('base64') +
                   '\t' + secret.toString('base64'));
        }
        console.log(out.join('\n'));
        """.trimIndent(),
    )
    val (status, text) = run(listOf(node, "check.js"), scratch)
    if (status != 0) {
        check(false, "real node graded the agreement corpus:\n${text.take(600)}")
        return
    }

    var used = 0
    var agreed = 0
    val privateByCurve = exchanges.associate { it.split("\t")[0] to it.split("\t")[1] }
    for (line in text.trim().lines()) {
        val parts = line.split("\t")
        when {
            parts.size == 3 && parts[0] == "use" -> {
                used += 1
                check(parts[2] == "true", "real node uses the key this generated — ${parts[1]}")
            }
            parts.size == 4 && parts[0] == "ecdh" -> {
                agreed += 1
                val curve = parts[1]
                val ours = NodeKeys.ecdhCompute(curve, privateByCurve[curve] ?: "", parts[2])
                checkEqual(ours ?: "<null>", parts[3], "ECDH agrees with node's half — $curve")
            }
        }
    }
    check(used == generated.size, "node graded every generated key — $used of ${generated.size}")
    check(agreed == exchanges.size, "every curve exchanged — $agreed of ${exchanges.size}")

    // A peer point that is not the uncompressed form is refused, not guessed at.
    check(
        NodeKeys.ecdhCompute(
            "prime256v1", privateByCurve["prime256v1"] ?: "",
            Base64.getEncoder().encodeToString(byteArrayOf(0x02) + ByteArray(32)),
        ) == null,
        "a compressed peer point is refused rather than misread",
    )
    check(
        NodeKeys.generate("ec", "secp256k1") == null,
        "a curve outside P-256/384/521 refuses at generation too",
    )
}

/**
 * RSA used as a cipher — `publicEncrypt`/`privateDecrypt` and the type-1 pair.
 *
 * OAEP and PKCS#1 v1.5 are both randomised, so once again the equality is not the ciphertext but
 * the round trip, and it has to CROSS: node seals and this opens, this seals and node opens. A
 * padding scheme that is wrong in a consistent way opens its own output and nothing else — and
 * OAEP has a specific way to be quietly wrong, since the digest and the MGF1 function are chosen
 * separately and a mismatched pair still encrypts.
 */
private fun rsaCipherCorpus(node: String?, parent: File) {
    if (node == null) {
        check(true, "RSA cipher corpus skipped — no real node to grade against")
        return
    }
    val scratch = File(parent, "rsacipher").also { it.mkdirs() }
    val secret = "attack at dawn — ÿ"
    val secretBase64 = Base64.getEncoder().encodeToString(secret.toByteArray(Charsets.UTF_8))
    val digests = listOf("sha1", "sha256", "sha384", "sha512")

    File(scratch, "seal.js").writeText(
        """
        const crypto = require('crypto');
        const fs = require('fs');
        const message = Buffer.from(${Json.write(secretBase64)}, 'base64');
        const k = crypto.generateKeyPairSync('rsa', { modulusLength: 2048,
          publicKeyEncoding: { type: 'spki', format: 'pem' },
          privateKeyEncoding: { type: 'pkcs8', format: 'pem' } });
        fs.writeFileSync('private.pem', k.privateKey);
        fs.writeFileSync('public.pem', k.publicKey);
        const out = [];
        for (const oaepHash of ${Json.write(digests)}) {
          const sealed = crypto.publicEncrypt(
            { key: k.publicKey, padding: crypto.constants.RSA_PKCS1_OAEP_PADDING, oaepHash },
            message);
          out.push('oaep\t' + oaepHash + '\t' + sealed.toString('base64'));
        }
        out.push('pkcs1\t\t' + crypto.publicEncrypt(
          { key: k.publicKey, padding: crypto.constants.RSA_PKCS1_PADDING }, message)
          .toString('base64'));
        // The type-1 direction: node signs with the private key, this must open it publicly.
        out.push('type1\t\t' + crypto.privateEncrypt(k.privateKey, message).toString('base64'));
        console.log(out.join('\n'));
        """.trimIndent(),
    )
    val (status, text) = run(listOf(node, "seal.js"), scratch)
    if (status != 0) {
        check(false, "real node sealed the RSA corpus:\n${text.take(600)}")
        return
    }
    val privatePem = File(scratch, "private.pem").readText()
    val publicPem = File(scratch, "public.pem").readText()

    // node sealed → this opens.
    var opened = 0
    for (line in text.trim().lines()) {
        val parts = line.split("\t")
        if (parts.size != 3) continue
        opened += 1
        val (kind, digest, sealed) = parts
        val plain = when (kind) {
            "oaep" -> NodeKeys.rsaDecrypt(privatePem, sealed, 4, digest)
            "pkcs1" -> NodeKeys.rsaDecrypt(privatePem, sealed, 1, "sha1")
            else -> NodeKeys.rsaPublicDecrypt(publicPem, sealed)
        }
        checkEqual(
            plain ?: "<null>", secretBase64,
            "opens what node sealed — $kind${if (digest.isEmpty()) "" else "/$digest"}",
        )
    }
    check(opened == digests.size + 2, "node sealed every case — $opened of ${digests.size + 2}")

    // this seals → node opens.
    val ours = ArrayList<String>()
    for (digest in digests) {
        val sealed = NodeKeys.rsaEncrypt(publicPem, secretBase64, 4, digest)
        check(sealed != null, "seals with OAEP/$digest")
        ours.add("oaep\t$digest\t${sealed ?: ""}")
    }
    NodeKeys.rsaEncrypt(publicPem, secretBase64, 1, "sha1").let {
        check(it != null, "seals with PKCS#1 v1.5")
        ours.add("pkcs1\t\t${it ?: ""}")
    }
    NodeKeys.rsaPrivateEncrypt(privatePem, secretBase64).let {
        check(it != null, "seals with the private key — the type-1 primitive")
        ours.add("type1\t\t${it ?: ""}")
    }
    File(scratch, "ours.tsv").writeText(ours.joinToString("\n"))

    File(scratch, "open.js").writeText(
        """
        const crypto = require('crypto');
        const fs = require('fs');
        const expected = ${Json.write(secretBase64)};
        const priv = fs.readFileSync('private.pem', 'utf8');
        const pub = fs.readFileSync('public.pem', 'utf8');
        const out = [];
        for (const line of fs.readFileSync('ours.tsv', 'utf8').split('\n')) {
          if (!line.trim()) continue;
          const [kind, digest, sealed] = line.split('\t');
          let ok = false;
          try {
            const bytes = Buffer.from(sealed, 'base64');
            const plain = kind === 'oaep'
              ? crypto.privateDecrypt({ key: priv,
                  padding: crypto.constants.RSA_PKCS1_OAEP_PADDING, oaepHash: digest }, bytes)
              : kind === 'pkcs1'
                ? crypto.privateDecrypt({ key: priv,
                    padding: crypto.constants.RSA_PKCS1_PADDING }, bytes)
                : crypto.publicDecrypt(pub, bytes);
            ok = plain.toString('base64') === expected;
          } catch (e) { ok = false; }
          out.push(kind + (digest ? '/' + digest : '') + '\t' + ok);
        }
        console.log(out.join('\n'));
        """.trimIndent(),
    )
    val (openStatus, openText) = run(listOf(node, "open.js"), scratch)
    if (openStatus != 0) {
        check(false, "real node opened our RSA corpus:\n${openText.take(600)}")
        return
    }
    var crossed = 0
    for (line in openText.trim().lines()) {
        val parts = line.split("\t")
        if (parts.size != 2) continue
        crossed += 1
        check(parts[1] == "true", "real node opens what this sealed — ${parts[0]}")
    }
    check(crossed == ours.size, "node graded every sealed case — $crossed of ${ours.size}")

    // The digest is not decoration: OAEP sealed under one hash must NOT open under another.
    val underSha256 = NodeKeys.rsaEncrypt(publicPem, secretBase64, 4, "sha256")
    check(
        NodeKeys.rsaDecrypt(privatePem, underSha256 ?: "", 4, "sha512") == null,
        "OAEP under one digest does not open under another",
    )
    check(
        NodeKeys.rsaDecrypt(privatePem, underSha256 ?: "", 1, "sha1") == null,
        "OAEP does not open as PKCS#1 v1.5",
    )
    check(
        NodeKeys.rsaEncrypt(publicPem, secretBase64, 3, "sha1") == null,
        "a padding mode this does not implement refuses rather than guessing",
    )
}

private fun zlibCorpus(node: String?, parent: File) {
    if (node == null) {
        check(true, "zlib corpus skipped — no real node to grade against")
        return
    }
    val scratch = File(parent, "zlib").also { it.mkdirs() }
    val samples = listOf(
        "" to "empty",
        "a" to "one byte",
        "hello world" to "a short string",
        "ab".repeat(5000) to "10 KB that compresses hard",
        (0..2000).joinToString(" ") { it.toString() } to "2 KB of numbers",
    )
    val deflaters = listOf("gzip" to "gunzip", "deflate" to "inflate", "deflateRaw" to "inflateRaw")

    for ((text, label) in samples) {
        val plain = Base64.getEncoder().encodeToString(text.toByteArray(Charsets.UTF_8))
        for ((deflate, inflate) in deflaters) {
            // 1. ours in, ours out.
            val ours = NodeZlib.transform(deflate, plain, -1)
            val back = ours?.let { NodeZlib.transform(inflate, it, -1) }
            checkEqual(back ?: "<null>", plain, "zlib $deflate/$inflate round-trips here: $label")

            // 2. ours in, NODE out — this is what catches a self-consistent wrong frame.
            if (ours != null) {
                File(scratch, "in.b64").writeText(ours)
                File(scratch, "run.js").writeText(
                    """
                    const fs = require('fs'), zlib = require('zlib');
                    const input = Buffer.from(fs.readFileSync('in.b64', 'utf8'), 'base64');
                    process.stdout.write(zlib.${inflate}Sync(input).toString('base64'));
                    """.trimIndent(),
                )
                val (status, out) = run(listOf(node, "run.js"), scratch)
                checkEqual(
                    if (status == 0) out.trim() else "<exit $status: ${out.trim().take(200)}>",
                    plain,
                    "real node $inflate accepts what we $deflate: $label",
                )
            }

            // 3. NODE in, ours out.
            File(scratch, "plain.b64").writeText(plain)
            File(scratch, "make.js").writeText(
                """
                const fs = require('fs'), zlib = require('zlib');
                const input = Buffer.from(fs.readFileSync('plain.b64', 'utf8'), 'base64');
                process.stdout.write(zlib.${deflate}Sync(input).toString('base64'));
                """.trimIndent(),
            )
            val (madeStatus, made) = run(listOf(node, "make.js"), scratch)
            if (madeStatus == 0) {
                checkEqual(
                    NodeZlib.transform(inflate, made.trim(), -1) ?: "<null>",
                    plain,
                    "we $inflate what real node $deflate: $label",
                )
            }
        }
    }

    // The streaming path is a SEPARATE implementation of the same framing, so it gets the same
    // treatment: chunks in, and real node must accept the result.
    for ((deflate, inflate) in deflaters) {
        val handle = NodeZlib.open(deflate)
        check(handle != 0, "zlibOpen($deflate) answers a handle")
        if (handle == 0) continue
        val chunks = listOf("streaming ", "in ", "several ", "pieces")
        val body = StringBuilder()
        for ((i, chunk) in chunks.withIndex()) {
            val piece = NodeZlib.push(
                handle,
                Base64.getEncoder().encodeToString(chunk.toByteArray(Charsets.UTF_8)),
                i == chunks.lastIndex,
            )
            if (piece != null && piece.isNotEmpty()) {
                body.append(String(Base64.getDecoder().decode(piece), Charsets.ISO_8859_1))
            }
        }
        NodeZlib.close(handle)
        val whole = Base64.getEncoder().encodeToString(body.toString().toByteArray(Charsets.ISO_8859_1))
        File(scratch, "in.b64").writeText(whole)
        File(scratch, "run.js").writeText(
            """
            const fs = require('fs'), zlib = require('zlib');
            const input = Buffer.from(fs.readFileSync('in.b64', 'utf8'), 'base64');
            process.stdout.write(zlib.${inflate}Sync(input).toString('utf8'));
            """.trimIndent(),
        )
        val (status, out) = run(listOf(node, "run.js"), scratch)
        checkEqual(
            if (status == 0) out.trimEnd('\n') else "<exit $status: ${out.trim().take(200)}>",
            chunks.joinToString(""),
            "real node $inflate accepts a STREAMED $deflate",
        )
    }

    check(NodeZlib.open("nope") == 0, "an unknown zlib mode answers handle 0")
    check(NodeZlib.transform("nope", "", -1) == null, "an unknown one-shot mode answers null")
    check(NodeZlib.push(999999, "", true) == null, "pushing to a handle that was never open answers null")
}

// ------------------------------------------------------------------------ ciphers ----

/**
 * Symmetric ciphers, graded BOTH DIRECTIONS against real node — for the reason zlib is.
 *
 * A cipher that round-trips only through itself proves nothing about interoperability: a wrong
 * counter, a tag on the wrong end, or a key schedule fed the bytes in the wrong order all decrypt
 * their own output perfectly. So node decrypts what we encrypt, and we decrypt what node
 * encrypted, and for the AEADs the TAG has to survive that crossing too.
 */
private fun cipherCorpus(node: String?, parent: File) {
    if (node == null) {
        check(true, "cipher corpus skipped — no real node to grade against")
        return
    }
    val scratch = File(parent, "ciphers").also { it.mkdirs() }
    val b64 = { value: String -> Base64.getEncoder().encodeToString(value.toByteArray(Charsets.UTF_8)) }
    val hex = { n: Int -> Base64.getEncoder().encodeToString(ByteArray(n) { (it * 7 + 3).toByte() }) }

    // (algorithm, key bytes, iv bytes, is it an AEAD)
    val suite = listOf(
        Triple("aes-128-gcm", 16, 12) to true,
        Triple("aes-256-gcm", 32, 12) to true,
        Triple("chacha20-poly1305", 32, 12) to true,
        Triple("aes-128-cbc", 16, 16) to false,
        Triple("aes-256-cbc", 32, 16) to false,
        Triple("aes-256-ctr", 32, 16) to false,
    )
    val plain = "attack at dawn, and bring the good biscuits"

    for ((spec, aead) in suite) {
        val (algorithm, keyLen, ivLen) = spec
        val key = hex(keyLen)
        val iv = hex(ivLen)
        val aad = if (aead) b64("some associated data") else ""

        val sealed = NodeCrypto.cipherSeal(algorithm, key, iv, b64(plain), aad)
        check(sealed != null, "$algorithm encrypts")
        if (sealed == null) continue
        val (data, tag) = sealed
        if (aead) check(tag.isNotEmpty(), "$algorithm produces an auth tag")

        // ours in, ours out
        checkEqual(
            NodeCrypto.cipherOpen(algorithm, key, iv, data, tag, aad)?.let {
                String(Base64.getDecoder().decode(it), Charsets.UTF_8)
            } ?: "<null>",
            plain,
            "$algorithm round-trips here",
        )

        // ours in, NODE out
        File(scratch, "open.js").writeText(
            """
            const crypto = require('crypto');
            const key = Buffer.from(${Json.write(key)}, 'base64');
            const iv = Buffer.from(${Json.write(iv)}, 'base64');
            const d = crypto.createDecipheriv(${Json.write(algorithm)}, key, iv);
            ${if (aead) "d.setAAD(Buffer.from(${Json.write(aad)}, 'base64'));\n            d.setAuthTag(Buffer.from(${Json.write(tag)}, 'base64'));" else ""}
            const out = Buffer.concat([d.update(Buffer.from(${Json.write(data)}, 'base64')), d.final()]);
            process.stdout.write(out.toString('utf8'));
            """.trimIndent(),
        )
        val (openStatus, opened) = run(listOf(node, "open.js"), scratch)
        checkEqual(
            if (openStatus == 0) opened.trimEnd('\n') else "<exit $openStatus: ${opened.trim().take(160)}>",
            plain,
            "real node decrypts what we $algorithm",
        )

        // NODE in, ours out
        File(scratch, "seal.js").writeText(
            """
            const crypto = require('crypto');
            const key = Buffer.from(${Json.write(key)}, 'base64');
            const iv = Buffer.from(${Json.write(iv)}, 'base64');
            const c = crypto.createCipheriv(${Json.write(algorithm)}, key, iv);
            ${if (aead) "c.setAAD(Buffer.from(${Json.write(aad)}, 'base64'));" else ""}
            const body = Buffer.concat([c.update(Buffer.from(${Json.write(b64(plain))}, 'base64')), c.final()]);
            process.stdout.write(body.toString('base64') + '\n' + ${if (aead) "c.getAuthTag().toString('base64')" else "''"});
            """.trimIndent(),
        )
        val (sealStatus, madeRaw) = run(listOf(node, "seal.js"), scratch)
        if (sealStatus == 0) {
            val lines = madeRaw.trimEnd('\n').split("\n")
            val theirData = lines.getOrElse(0) { "" }
            val theirTag = lines.getOrElse(1) { "" }
            checkEqual(
                NodeCrypto.cipherOpen(algorithm, key, iv, theirData, theirTag, aad)?.let {
                    String(Base64.getDecoder().decode(it), Charsets.UTF_8)
                } ?: "<null>",
                plain,
                "we decrypt what real node $algorithm",
            )
            // The ciphertext itself must be identical, not merely mutually decodable — a mode
            // that differs here still interoperates by luck rather than by agreeing.
            checkEqual(theirData, data, "$algorithm produces the same ciphertext as node")
            if (aead) checkEqual(theirTag, tag, "$algorithm produces the same auth tag as node")
        }
    }

    // An AEAD whose tag has been touched must FAIL, not decrypt to something. This is the one
    // check that separates authenticated encryption from encryption.
    val key = hex(32)
    val iv = hex(12)
    val sealed = NodeCrypto.cipherSeal("aes-256-gcm", key, iv, b64(plain), "")
    check(sealed != null, "aes-256-gcm seals for the tamper check")
    if (sealed != null) {
        val bytes = Base64.getDecoder().decode(sealed.second)
        bytes[0] = (bytes[0].toInt() xor 0x01).toByte()
        val tampered = Base64.getEncoder().encodeToString(bytes)
        check(
            NodeCrypto.cipherOpen("aes-256-gcm", key, iv, sealed.first, tampered, "") == null,
            "a tampered GCM tag refuses rather than decrypting",
        )
    }
    check(NodeCrypto.cipherSeal("aes-256-gcm", hex(16), iv, b64("x"), "") == null, "a wrong key length refuses")
    check(NodeCrypto.cipherSeal("nope-256-gcm", key, iv, b64("x"), "") == null, "an unknown cipher refuses")
}
