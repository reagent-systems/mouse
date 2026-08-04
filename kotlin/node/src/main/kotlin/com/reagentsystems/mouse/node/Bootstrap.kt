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
