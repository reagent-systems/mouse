package com.reagentsystems.mouse.node

/**
 * The JS bootstrap — the ~14,000-line JavaScript half of the Node layer — and the one transform
 * that turns the iOS original into the Android asset.
 *
 * The bootstrap is NOT rewritten for Android. It is a Swift raw string literal inside
 * `swift/Mouse/NodeEngine.swift`, and `plans/android-parity.md` measured it as the portable
 * 72 % of the engine; the host bridge is the 28 % that gets written in Kotlin. So the asset at
 * [ASSET_PATH] is a byte-for-byte copy of that literal's contents, and this object owns the
 * extraction that produces it — used BOTH to write the asset and to grade it, so the transform
 * cannot be right in one direction and wrong in the other.
 *
 * The literal is a Swift RAW string (`#"""` … `"""#`). Two properties of that form are what make
 * a verbatim copy possible at all, and both are asserted rather than assumed:
 *
 *  - Raw means no escape processing. `\n` in the JS stays two characters. The only escapes a
 *    `#`-delimited literal recognises are `\#`-prefixed ones (`\#n`, `\#(…)` interpolation), so
 *    if any `\#` appears the copy would need real unescaping and [extract] refuses instead of
 *    guessing.
 *  - Swift strips, from every line, the indentation of the CLOSING delimiter. That is the only
 *    transform applied here, and it is applied exactly: a content line must either be empty or
 *    start with that indentation, or the extraction fails.
 */
object Bootstrap {

    /** Path, relative to the repo root, of the Swift file that owns the original. */
    const val SWIFT_PATH: String = "swift/Mouse/NodeEngine.swift"

    /** Path, relative to the repo root, of the Android asset that must equal it. */
    const val ASSET_PATH: String = "kotlin/app/src/main/assets/node-bootstrap.js"

    /** Asset name as the WebView host asks for it. */
    const val ASSET_NAME: String = "node-bootstrap.js"

    private const val OPEN_DELIMITER = "private static let bootstrap = #\"\"\""
    private const val CLOSE_DELIMITER = "\"\"\"#"

    class ExtractionFailure(message: String) : RuntimeException(message)

    /**
     * Pull the bootstrap's JavaScript out of the text of `NodeEngine.swift`.
     *
     * Returns the JS with a single trailing newline, which is what a file on disk carries.
     */
    fun extract(swiftSource: String): String {
        val lines = swiftSource.split("\n")

        val openIndices = lines.indices.filter { lines[it].trim() == OPEN_DELIMITER }
        if (openIndices.size != 1) {
            throw ExtractionFailure(
                "expected exactly one `$OPEN_DELIMITER` in $SWIFT_PATH, found ${openIndices.size}",
            )
        }
        val open = openIndices.single()

        var close = -1
        for (i in (open + 1) until lines.size) {
            if (lines[i].trim() == CLOSE_DELIMITER) {
                close = i
                break
            }
        }
        if (close < 0) {
            throw ExtractionFailure(
                "no closing `$CLOSE_DELIMITER` after line ${open + 1} of $SWIFT_PATH",
            )
        }

        // Swift's own rule: the closing delimiter's indentation is stripped from every line.
        val indent = lines[close].takeWhile { it == ' ' || it == '\t' }

        val body = ArrayList<String>(close - open)
        for (i in (open + 1) until close) {
            val line = lines[i]
            when {
                line.isEmpty() -> body.add("")
                line.startsWith(indent) -> body.add(line.substring(indent.length))
                // A line that is only whitespace, shorter than the indent, is still legal Swift.
                line.isBlank() -> body.add("")
                else -> throw ExtractionFailure(
                    "line ${i + 1} of $SWIFT_PATH is inside the bootstrap but is not indented to " +
                        "the closing delimiter (${indent.length} spaces): ${line.take(60)}",
                )
            }
        }

        val text = body.joinToString("\n")
        // A raw literal with a `#` delimiter processes exactly one family of escapes. If one is
        // present the bytes here are not the bytes Swift sees, and a "verbatim copy" would be a
        // lie — fail loudly rather than ship a subtly different engine.
        val escape = text.indexOf("\\#")
        if (escape >= 0) {
            val line = text.substring(0, escape).count { it == '\n' } + 1
            throw ExtractionFailure(
                "the bootstrap contains a `\\#` raw-string escape at extracted line $line; the " +
                    "copy is no longer verbatim and this transform must learn to unescape it",
            )
        }
        return text + "\n"
    }

    private val GLOBAL_ASSIGNMENT =
        Regex("""\bglobalThis\.([A-Za-z_$][A-Za-z0-9_$]*)\s*=(?!=)""")

    /** Every `globalThis.<name> =` the bootstrap performs. */
    fun assignedGlobals(bootstrapJs: String): Set<String> =
        GLOBAL_ASSIGNMENT.findAll(bootstrapJs).map { it.groupValues[1] }.toSortedSet()

    /**
     * Make every global the bootstrap ASSIGNS assignable, before it runs.
     *
     * This has no iOS counterpart and needs one on Android. JavaScriptCore hands the engine a
     * bare `JSContext` whose global object owns almost nothing; a WebView's global object is a
     * `Window`, and some of what the bootstrap installs is already there as a GETTER —
     * `globalThis.crypto = {…}` against an accessor with no setter throws
     * `TypeError: Cannot set property crypto of #<Object> which has only a getter`, in strict
     * mode, at line 768 of 13,993, taking the whole engine with it.
     *
     * The list is derived from the shipping bootstrap rather than written by hand, so a global
     * added on the iOS side is unlocked here without anyone remembering to. Properties that are
     * already plain writable data are left alone, and one that cannot be redefined at all is left
     * to fail at the assignment — a silent skip there would just move the error somewhere worse.
     */
    fun unlockGlobalsScript(bootstrapJs: String): String {
        val names = assignedGlobals(bootstrapJs).joinToString(",") { HostBridge.jsString(it) }
        return """
            (function(){
              var names = [$names];
              for (var i = 0; i < names.length; i++) {
                var name = names[i];
                var descriptor;
                try { descriptor = Object.getOwnPropertyDescriptor(globalThis, name); }
                catch (e) { continue; }
                if (!descriptor || !descriptor.configurable) continue;
                if (descriptor.writable === true) continue;
                var current;
                try { current = descriptor.get ? descriptor.get.call(globalThis) : descriptor.value; }
                catch (e) { current = undefined; }
                try {
                  Object.defineProperty(globalThis, name, {
                    value: current, writable: true, configurable: true,
                    enumerable: descriptor.enumerable,
                  });
                } catch (e) {}
              }
            })();
        """.trimIndent()
    }

    /**
     * Keep V8's own async `WebAssembly` around while the bootstrap replaces it, and put it back
     * afterwards. Evaluate [KEEP_NATIVE_WASM] before the bootstrap and [RESTORE_NATIVE_WASM]
     * after it.
     *
     * The bootstrap defines `WebAssembly.compile` and `.instantiate` as the SYNCHRONOUS
     * constructors wrapped in a resolved promise, and says why: JavaScriptCore's async wasm
     * functions never settle on a bare `JSContext`, because nothing runs the runloop their
     * completion needs. That is true, and it is a JSC fact.
     *
     * On V8 it is worse than unnecessary. The async functions are real here, and the SYNCHRONOUS
     * ones are the ones that are restricted: `new WebAssembly.Module(bytes)` throws for a buffer
     * over 8 MB on the main thread, which is the only thread a WebView's JavaScript has. So the
     * polyfill takes a working call and replaces it with one that cannot succeed —
     * `python.wasm` is 14 MB, and `python hello.py` failed with exactly that RangeError, raised
     * from inside the polyfill rather than from the caller.
     *
     * This is not a patch of shared behaviour. The two engines genuinely disagree about which
     * half of the wasm API works, so the host that knows which engine it is puts back the half
     * that does — the same reasoning as [unlockGlobalsScript], one layer up.
     */
    const val KEEP_NATIVE_WASM: String = """
        globalThis.__mouseNativeWasm = (typeof WebAssembly === 'object' && WebAssembly)
          ? { compile: WebAssembly.compile, instantiate: WebAssembly.instantiate }
          : null;
    """

    /** @see KEEP_NATIVE_WASM */
    const val RESTORE_NATIVE_WASM: String = """
        (function () {
          var native = globalThis.__mouseNativeWasm;
          if (!native) return;
          if (typeof native.compile === 'function') WebAssembly.compile = native.compile;
          if (typeof native.instantiate === 'function') WebAssembly.instantiate = native.instantiate;
          delete globalThis.__mouseNativeWasm;
        })();
    """

    /**
     * Tell the engine which machine it is actually on. Evaluate AFTER the bootstrap.
     *
     * The bootstrap hardcodes `process.platform = 'darwin'`, `os.type() = 'Darwin'` and an
     * `arm64` arch, and on iOS every one of those is TRUE. On Android none of them is, and this
     * is not cosmetic: packages branch on `process.platform` to pick a binary, a path separator
     * or a code path. napi-rs's generated loader is the one already in this tree's way — it
     * reaches for `<name>.<platform>-<arch>.node` before it will consider the WebAssembly build.
     * Lying about the platform is how a package ends up looking for a darwin artifact on a phone.
     *
     * The values come from the HOST because only the host knows them, the same rule the
     * nameservers follow. `android` is what node itself reports when built for this platform, and
     * a package that does not know it falls through to its POSIX branch, which is the right one —
     * Android is Linux underneath, which is also why `os.type()` is `Linux`.
     *
     * Applied by `NodeWebView` on device and by `:nodecheck`'s driver off it, from the same
     * function with the same arguments, so the two hosts cannot answer differently.
     */
    fun platformScript(platform: String, type: String, arch: String, release: String): String {
        val q = HostBridge::jsString
        return """
            (function () {
              var process = globalThis.process;
              if (process) {
                try { process.platform = ${q(platform)}; } catch (e) {}
                try { process.arch = ${q(arch)}; } catch (e) {}
              }
              // `os` is a CORE MODULE built by a factory and cached on first require, so the
              // patch has to go through the same require the program will use — reaching for a
              // fresh factory would leave the cached copy still answering Darwin.
              try {
                var os = globalThis.__mouseRequire ? globalThis.__mouseRequire('os') : null;
                if (os) {
                  os.platform = function () { return ${q(platform)}; };
                  os.type = function () { return ${q(type)}; };
                  os.arch = function () { return ${q(arch)}; };
                  os.release = function () { return ${q(release)}; };
                }
              } catch (e) {}
            })();
        """.trimIndent()
    }

    /**
     * Where the two texts first differ, as a human-readable line, or null when they match.
     * Reported by LABEL — line number and both texts — rather than by index into a diff, for
     * the reason AGENTS.md records: one divergence shifts every later line.
     */
    fun firstDifference(expected: String, actual: String): String? {
        if (expected == actual) return null
        val a = expected.split("\n")
        val b = actual.split("\n")
        val shared = minOf(a.size, b.size)
        for (i in 0 until shared) {
            if (a[i] != b[i]) {
                return "line ${i + 1}\n" +
                    "      swift:  ${a[i].take(120)}\n" +
                    "      asset:  ${b[i].take(120)}"
            }
        }
        return "line count: swift has ${a.size}, asset has ${b.size} " +
            "(first ${shared} lines identical)"
    }
}
