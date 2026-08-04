package com.reagentsystems.mouse.nodecheck

import com.reagentsystems.mouse.node.Bootstrap
import com.reagentsystems.mouse.node.HostBridge
import com.reagentsystems.mouse.node.NodeLoop
import com.reagentsystems.mouse.node.NodeProcessConfig
import com.reagentsystems.mouse.node.NodeSmoke
import java.io.File
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
                "    regenerate with: ./gradlew :nodecheck:run -PnodecheckArgs=--sync",
        )
    }
    return extracted
}

// ------------------------------------------------------------------------ bridge ----------

private fun bridgeCorpus(bootstrap: String) {
    if (bootstrap.isEmpty()) return
    val referenced = HostBridge.referencedNames(bootstrap)
    check(referenced.size > 80, "the bootstrap's bridge surface was found (${referenced.size} names)")

    val accounted = HostBridge.IMPLEMENTED + HostBridge.DEFERRED
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
    val overlap = HostBridge.IMPLEMENTED intersect HostBridge.DEFERRED
    check(overlap.isEmpty(), "no bridge name is both implemented and deferred (both: $overlap)")

    // The three the bootstrap calls at its TOP LEVEL cannot be stubs: it would throw while
    // loading, and the whole engine would be gone with no error a user could act on.
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

    File(scratch, "node-host.js").writeText(shimFile.readText())
    File(scratch, "stubs.js").writeText(HostBridge.deferredStubScript())
    File(scratch, "unlock.js").writeText(Bootstrap.unlockGlobalsScript(bootstrap))
    File(scratch, "globals.js").writeText(NodeSmoke.CONFIG.globalsScript())
    File(scratch, "program.js").writeText(NodeSmoke.PROGRAM)
    File(scratch, "driver.js").writeText(DRIVER)

    val (status, text) = run(listOf(node, "driver.js"), scratch)
    check(status == 0, "the load smoke ran (exit $status)\n${text.trim().take(1500)}")
    if (status != 0) return

    val loadError = File(scratch, "load-error.txt")
    check(!loadError.exists(), "the engine loads against the Android bridge: ${if (loadError.exists()) loadError.readText().take(600) else ""}")
    val entryError = File(scratch, "entry-error.txt")
    check(!entryError.exists(), "the program runs without throwing: ${if (entryError.exists()) entryError.readText().take(600) else ""}")
    if (loadError.exists() || entryError.exists()) return

    val stdout = File(scratch, "out.txt").readText()
    val stderr = File(scratch, "err.txt").readText()
    val exit = File(scratch, "exit.txt").readText().trim().toIntOrNull() ?: -1
    val smokeFailures = NodeSmoke.grade(stdout, stderr, exit)
    checks += NodeSmoke.CHECK_COUNT
    failures += smokeFailures.size
    for (failure in smokeFailures) println("  FAIL: $failure")
}

/**
 * The load smoke's driver, in JavaScript, because that is the only language both halves speak.
 *
 * It stands in for NodeWebView: the same five scripts in the same order, the same `__mouseHost`
 * method set, the same id-registry timer protocol, and the same one-turn-per-dispatch loop — with
 * a REAL macrotask boundary between turns, which is what an `evaluateJavascript` call is. The
 * clock is virtual, so the smoke costs no wall time and cannot flake on a slow machine.
 */
private val DRIVER = """
    'use strict';
    const fs = require('fs');

    // Real node's, captured BEFORE the bootstrap replaces the globals with the engine's. After
    // the load, `console` writes into the engine's stdout sink and `setImmediate` is the engine's
    // — a driver that had not saved these would be reporting into the thing it is testing.
    const realProcess = process;
    const realSetImmediate = setImmediate;

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
    };

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
      const result = JSON.parse(
        globalThis.__mouseDispatch.entry(fs.readFileSync('program.js', 'utf8'), '/nodecheck.js'));
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

    val scratch = File(System.getProperty("java.io.tmpdir"), "nodecheck-${ProcessHandle.current().pid()}")
    scratch.mkdirs()
    try {
        nodeCorpus(bootstrap, scratch)
    } finally {
        scratch.deleteRecursively()
    }

    if (failures == 0) {
        println(
            "NODE LAYER: $checks checks — bootstrap drift vs swift/Mouse/NodeEngine.swift, bridge " +
                "partition, process globals, event loop, node --check, load smoke — MATCH",
        )
    } else {
        println("NODE LAYER: $failures of $checks checks failed — MISMATCH")
        exitProcess(1)
    }
}
