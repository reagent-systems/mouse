package com.reagentsystems.mouse.node

import java.util.regex.Matcher
import java.util.regex.Pattern

/**
 * ES modules → CommonJS, by source rewrite. `NodeEngine.rewriteImportForms` and
 * `NodeEngine.transpileESM` ported from Swift.
 *
 * ## Why a transpiler exists at all
 *
 * Neither engine has a module loader wired to our resolver, so `import` cannot be executed as
 * `import`. iOS answers by rewriting the source into CommonJS before evaluating it, and the
 * runtime the rewrite targets — `__esmDefault`, `__esmBinding`, `__mouseLive`, `__reexportStar`,
 * `__dynamicImport` — is in the SHARED bootstrap, so Android already had the second half of this
 * and none of the first. That is why `require()` of an ES module refused by name until now: the
 * rewriter is Swift, and Swift is not shared.
 *
 * ## Two rewrites, and why one is a scanner
 *
 * [rewriteImportForms] handles `import.meta` and dynamic `import(`, both of which are legal in
 * CommonJS too. It is a SCANNER, not a regex, because a real bundle carries JavaScript inside
 * string literals — vite ships the browser's own `import.meta.hot` as a template string it serves
 * to the client — and a blind replace edits code that was never ours. It tracks quotes, template
 * literals with `${}` nesting, both comment forms, and regex literals; the last is why a smarter
 * regex will not do, since `/["']/` is a legal regex whose quote would open a string that never
 * closes.
 *
 * [transpile] handles the statement grammar, pattern by pattern, and every pattern is matched
 * against a MASK — the same bytes with strings, comments and regexes blanked to spaces — then
 * applied to the real text at those offsets. Without it, `export default function WorkerWrapper`
 * inside one of vite's generated worker strings gets rewritten as if it were code.
 *
 * The comments on the individual patterns are the Swift file's, kept because each one records a
 * package that broke: they are the enumeration, and a transpiler that works by pattern is only as
 * good as its enumeration of the grammar. `verify/esmgrammar` is where that enumeration is
 * checked against real node, and `:nodecheck` runs the same cases.
 */
object EsmTranspiler {

    /** The result of a scan: the rewritten text, and whether `import.meta` was actually used. */
    data class Scan(val text: String, val usedMeta: Boolean)

    private val REGEX_KEYWORDS = setOf(
        "return", "typeof", "instanceof", "in", "of", "new",
        "delete", "void", "throw", "do", "else", "case", "yield", "await",
    )

    /**
     * `import(spec)` → `__dynamicImport(__mouseRequire, spec)`, and optionally `import.meta` →
     * `__mouseImportMeta`. Applied to ESM as part of the transpile AND to CommonJS that contains
     * a dynamic import, which is legal — prettier lazy-loads its plugins that way.
     *
     * In [mask] mode the same scan emits a copy in which every string, template chunk, comment
     * and regex body is blanked to spaces, with newlines and non-ASCII bytes kept so offsets and
     * line structure survive exactly.
     */
    fun rewriteImportForms(source: String, meta: Boolean, mask: Boolean = false): Scan {
        if (!mask && !source.contains("import")) return Scan(source, false)
        val bytes = source.toByteArray(Charsets.UTF_8)
        val count = bytes.size
        val out = java.io.ByteArrayOutputStream(count + 64)
        var usedMeta = false
        var index = 0

        // Template state: a frame per ` we are inside ('t') and per `${` inside one ('s').
        val frames = ArrayList<Pair<Int, Int>>()
        var depth = 0
        var inTemplate = false
        // The last significant byte of code, and the last identifier, decide whether a '/' opens
        // a regex or divides — the one genuinely ambiguous character in the language.
        var lastCode = 0
        var lastWord = ""

        fun isIdent(byte: Int): Boolean =
            (byte in 0x41..0x5a) || (byte in 0x61..0x7a) || (byte in 0x30..0x39) ||
                byte == 0x5f || byte == 0x24 || byte >= 0x80

        fun regexCanStart(): Boolean {
            if (lastCode == 0) return true
            if (isIdent(lastCode)) return REGEX_KEYWORDS.contains(lastWord)
            return !(lastCode == 0x29 || lastCode == 0x5d) // not after ')' or ']'
        }

        fun emit(byte: Int) {
            out.write(byte)
            if (byte > 0x20) lastCode = byte
        }

        /** A byte inside a string, comment or regex: kept as itself, or blanked in mask mode. */
        fun copy(byte: Int) {
            out.write(if (mask && byte != 0x0a && byte < 0x80) 0x20 else byte)
        }

        fun at(i: Int): Int = bytes[i].toInt() and 0xff

        while (index < count) {
            val byte = at(index)

            if (inTemplate) {
                if (byte == 0x5c) { // \ escape
                    copy(byte); index += 1
                    if (index < count) { copy(at(index)); index += 1 }
                    continue
                }
                if (byte == 0x60) { // ` closes the template
                    copy(byte); index += 1
                    if (frames.isNotEmpty()) depth = frames.removeAt(frames.size - 1).second
                    inTemplate = false
                    lastCode = 0x60; lastWord = ""
                    continue
                }
                if (byte == 0x24 && index + 1 < count && at(index + 1) == 0x7b) { // ${
                    out.write(byte); out.write(at(index + 1)); index += 2
                    frames.add(0x73 to depth)
                    depth = 0
                    inTemplate = false
                    lastCode = 0x7b; lastWord = ""
                    continue
                }
                copy(byte); index += 1
                continue
            }

            if (byte == 0x2f && index + 1 < count && at(index + 1) == 0x2f) { // //
                while (index < count && at(index) != 0x0a) { copy(at(index)); index += 1 }
                continue
            }
            if (byte == 0x2f && index + 1 < count && at(index + 1) == 0x2a) { // /* */
                copy(byte); copy(at(index + 1)); index += 2
                while (index < count) {
                    if (at(index) == 0x2a && index + 1 < count && at(index + 1) == 0x2f) {
                        copy(at(index)); copy(at(index + 1)); index += 2
                        break
                    }
                    copy(at(index)); index += 1
                }
                continue
            }
            if (byte == 0x22 || byte == 0x27) { // " '
                // Kept verbatim even in mask mode: a quoted string cannot contain a real newline,
                // so a line-anchored pattern can never match inside one — and the module specifier
                // the import patterns have to READ is exactly here.
                out.write(byte); index += 1
                while (index < count) {
                    val inner = at(index)
                    out.write(inner); index += 1
                    if (inner == 0x5c) {
                        if (index < count) { out.write(at(index)); index += 1 }
                        continue
                    }
                    if (inner == byte || inner == 0x0a) break // a newline ends a broken string
                }
                lastCode = 0x22; lastWord = ""
                continue
            }
            if (byte == 0x60) { // ` opens
                copy(byte); index += 1
                frames.add(0x74 to depth)
                depth = 0
                inTemplate = true
                continue
            }
            if (byte == 0x2f && regexCanStart()) { // regex literal
                copy(byte); index += 1
                var inClass = false
                while (index < count) {
                    val inner = at(index)
                    copy(inner); index += 1
                    if (inner == 0x5c) {
                        if (index < count) { copy(at(index)); index += 1 }
                        continue
                    }
                    if (inner == 0x5b) { inClass = true; continue }
                    if (inner == 0x5d) { inClass = false; continue }
                    if (inner == 0x0a) break // not a regex after all
                    if (inner == 0x2f && !inClass) break
                }
                while (index < count && isIdent(at(index))) { copy(at(index)); index += 1 }
                lastCode = 0x2f; lastWord = ""
                continue
            }
            if (byte == 0x7b) { depth += 1; emit(byte); index += 1; lastWord = ""; continue }
            if (byte == 0x7d) {
                val frame = frames.lastOrNull()
                if (depth == 0 && frame != null && frame.first == 0x73) { // closes ${…}
                    frames.removeAt(frames.size - 1)
                    depth = frame.second
                    inTemplate = true
                    out.write(byte); index += 1
                    continue
                }
                depth -= 1
                emit(byte); index += 1; lastWord = ""
                continue
            }

            // An identifier — the only place `import` can start.
            if (isIdent(byte)) {
                var end = index
                while (end < count && isIdent(at(end))) end += 1
                val word = String(bytes, index, end - index, Charsets.UTF_8)
                val precededByDot = lastCode == 0x2e
                if (word == "import" && !precededByDot && !mask) {
                    var probe = end
                    while (probe < count && (at(probe) == 0x20 || at(probe) == 0x09 ||
                            at(probe) == 0x0a || at(probe) == 0x0d)
                    ) probe += 1
                    if (meta && probe < count && at(probe) == 0x2e) {
                        var afterDot = probe + 1
                        while (afterDot < count && (at(afterDot) == 0x20 || at(afterDot) == 0x09)) afterDot += 1
                        var metaEnd = afterDot
                        while (metaEnd < count && isIdent(at(metaEnd))) metaEnd += 1
                        if (String(bytes, afterDot, metaEnd - afterDot, Charsets.UTF_8) == "meta") {
                            out.write("__mouseImportMeta".toByteArray(Charsets.UTF_8))
                            usedMeta = true
                            index = metaEnd
                            lastCode = 0x61; lastWord = "__mouseImportMeta"
                            continue
                        }
                    }
                    if (probe < count && at(probe) == 0x28) { // import(
                        out.write("__dynamicImport(__mouseRequire, ".toByteArray(Charsets.UTF_8))
                        index = probe + 1
                        lastCode = 0x28; lastWord = ""
                        continue
                    }
                }
                out.write(bytes, index, end - index)
                lastCode = at(end - 1)
                lastWord = word
                index = end
                continue
            }

            emit(byte)
            index += 1
        }
        return Scan(String(out.toByteArray(), Charsets.UTF_8), usedMeta)
    }

    /** Dynamic `import()` in a CommonJS file — legal, and prettier lazy-loads plugins with it. */
    fun rewriteDynamicImport(source: String): String = rewriteImportForms(source, meta = false).text

    private fun isIdentifier(text: String): Boolean {
        val first = text.firstOrNull() ?: return false
        if (!(first.isLetter() || first == '_' || first == '$')) return false
        return text.all { it.isLetter() || it.isDigit() || it == '_' || it == '$' }
    }

    /**
     * `a, b as c, // comment` → [(a, a), (b, c)] — comments stripped, whitespace-split, junk
     * skipped.
     */
    private fun bindings(clause: String): List<Pair<String, String>> {
        var text = clause
        text = text.replace(Regex("//[^\n]*"), "")
        text = text.replace(Regex("/\\*[\\s\\S]*?\\*/"), "")
        val result = ArrayList<Pair<String, String>>()
        for (piece in text.split(",")) {
            val words = piece.split(Regex("\\s+")).filter { it.isNotEmpty() && it != "as" }
            val source = words.firstOrNull() ?: continue
            if (!isIdentifier(source)) continue
            val alias = if (words.size > 1) words[1] else source
            if (!isIdentifier(alias)) continue
            result.add(source to alias)
        }
        return result
    }

    /**
     * The names a destructuring pattern BINDS, which is not the same as the identifiers in it:
     * `{ a, b: c, d = 1, ...rest }` binds a, c, d and rest, and `b` is a key. Balanced scanning,
     * because a regex cannot find the end of a pattern that nests.
     */
    private fun destructuredNames(text: String, start: Int, masked: String): Pair<List<String>, Int> {
        val names = ArrayList<String>()
        var depth = 0
        var index = start
        var expectBinding = true // at the start of an element, before any ':'
        val inArray = ArrayList<Boolean>()
        while (index < masked.length) {
            val ch = masked[index]
            if (ch == '{' || ch == '[') {
                depth += 1
                inArray.add(ch == '[')
                expectBinding = true
                index += 1
                continue
            }
            if (ch == '}' || ch == ']') {
                depth -= 1
                if (inArray.isNotEmpty()) inArray.removeAt(inArray.size - 1)
                index += 1
                if (depth == 0) return names to index
                continue
            }
            if (ch == ',') { expectBinding = true; index += 1; continue }
            if (ch == ':') { expectBinding = true; index += 1; continue }
            if (ch == '=') {
                // A default value: skip to the next comma or closing brace at this depth.
                expectBinding = false
                index += 1
                continue
            }
            if (ch.isLetter() || ch == '_' || ch == '$') {
                var end = index
                while (end < masked.length) {
                    val next = masked[end]
                    if (!(next.isLetter() || next.isDigit() || next == '_' || next == '$')) break
                    end += 1
                }
                val word = text.substring(index, end)
                // In an object pattern `a:` is a KEY, so only take it when nothing follows that
                // makes it one; in an array pattern every identifier is a binding.
                var lookahead = end
                while (lookahead < masked.length && masked[lookahead] == ' ') lookahead += 1
                val followedByColon = lookahead < masked.length && masked[lookahead] == ':'
                if (expectBinding && !followedByColon) names.add(word)
                if (followedByColon) expectBinding = true
                index = end
                continue
            }
            index += 1
        }
        return names to index
    }

    /**
     * The whole transpile: ESM source in, CommonJS out.
     *
     * The pattern ORDER matters and is the Swift file's, comment for comment. Several rules are
     * prefixes of others (`export * as x from` before `export * from`; the string-named
     * `module.exports` idiom before the general clause), and a rule that ran second would never
     * fire.
     */
    fun transpile(source: String): String {
        var text = source
        // Emitted BEFORE the body: function declarations are hoisted, so a cycle reaching back
        // into this module finds them, and every export reads through a getter rather than being
        // frozen at end-of-module.
        val prologue = ArrayList<String>()
        var counter = 0
        var maskCache: String? = null

        /**
         * One pass per pattern: collect every match against the current text, then rebuild the
         * string ONCE. Matches are statement-anchored and non-overlapping, and replacements never
         * introduce new import/export syntax, so a single pass is equivalent.
         */
        fun replace(pattern: String, transform: (Matcher) -> String) {
            val regex = Pattern.compile(pattern, Pattern.MULTILINE)
            val matcher = regex.matcher(text)
            val found = ArrayList<IntArray>()
            val transformed = ArrayList<String>()
            // Match the text itself first — most patterns miss entirely, and the mask is only
            // worth building when there is something to judge.
            val candidates = ArrayList<Matcher>()
            val spans = ArrayList<IntArray>()
            while (matcher.find()) spans.add(intArrayOf(matcher.start(), matcher.end()))
            if (spans.isEmpty()) return
            if (maskCache == null) maskCache = rewriteImportForms(text, meta = false, mask = true).text
            val mask = maskCache
            if (mask == null || mask.length != text.length) return

            val second = regex.matcher(text)
            while (second.find()) {
                // A match is code when its OPENING survives masking; testing the opening rather
                // than the whole match keeps an import with a comment inside its braces, which
                // the mask blanks in the middle. From the first non-space character, because a
                // match anchored at `^` starts on the INDENTATION — spaces in both — so comparing
                // from the match start called every masked line code.
                var start = second.start()
                val end = second.end()
                while (start < end && (text[start] == ' ' || text[start] == '\t' ||
                        text[start] == '\n' || text[start] == '\r')
                ) start += 1
                if (start >= end) continue
                val headEnd = minOf(start + 8, end)
                if (mask.substring(start, headEnd) != text.substring(start, headEnd)) continue
                found.add(intArrayOf(second.start(), second.end()))
                transformed.add(transform(second))
            }
            if (found.isEmpty()) return

            val result = StringBuilder(text.length)
            var cursor = 0
            for ((i, span) in found.withIndex()) {
                if (span[0] > cursor) result.append(text, cursor, span[0])
                // A multi-line import becomes one line, and everything below it would move up by
                // the lines it swallowed — so the replacement carries them, at the end where they
                // change nothing but the count.
                val consumed = text.substring(span[0], span[1])
                val newlines = consumed.count { it == '\n' }
                result.append(transformed[i])
                repeat(newlines) { result.append('\n') }
                cursor = span[1]
            }
            if (cursor < text.length) result.append(text, cursor, text.length)
            text = result.toString()
            maskCache = null // the text moved under it
        }

        fun group(matcher: Matcher, index: Int): String? =
            if (index <= matcher.groupCount()) matcher.group(index) else null

        fun namedTemp(): String { counter += 1; return "__esm$counter" }

        // Every import site awaits ONLY a genuinely-pending (top-level-await) dependency:
        // `if (x instanceof Promise) x = await x`. A fully-sync dependency evaluates without
        // suspension, so sync modules stay sync under the async wrapper; a TLA dependency
        // suspends its importers — the same infection real ESM has.
        // `__esmSettle` rather than `await`, and that choice is what lets a module without
        // top-level await be wrapped in a SYNCHRONOUS function — which is the whole of node 22's
        // `require(esm)`. The call is legal in a sync function and in an async one alike, so the
        // same transpiled text serves both wrappers and `node-host.js` can re-wrap async on a
        // SyntaxError without asking for a different transpile.
        //
        // What it gives up: a dependency that is itself async can no longer be awaited here, and
        // raises `ERR_REQUIRE_ASYNC_MODULE` instead. That is node's own answer for the sync case,
        // and for the async case it is a narrowing — a module with top-level await importing
        // another module with top-level await. Recorded rather than hidden.
        fun requireSettled(temp: String, module: String): String =
            "let $temp = __esmSettle(__mouseRequire('$module'), '$module');"

        // import defaultName, { a, b as c } from 'mod'  (all combinations) / import * as ns —
        // minified bundles drop every optional space (`import{x as y}from"m"`).
        replace(
            """(?:^|(?<=[;}]))[ \t]*import\s*(?:([\w${'$'}]+)\s*,\s*)?(?:\{([^}]*)\}|\*\s*as\s+([\w${'$'}]+)|([\w${'$'}]+))\s*from\s*['"]([^'"]+)['"](?:\s*(?:with|assert)\s*\{[^}]*\})?\s*;?"""
        ) { m ->
            val temp = namedTemp()
            val lines = ArrayList<String>()
            lines.add(requireSettled(temp, group(m, 5)!!))
            val defaultName = group(m, 1) ?: group(m, 4)
            if (defaultName != null) lines.add("const $defaultName = __esmDefault($temp);")
            val named = group(m, 2)
            if (named != null) {
                // Read through __esmBinding, not destructured outright. In a CYCLE the exporting
                // module is still evaluating and its `const` is in TDZ — real ESM never reads it
                // there, because a binding is read where it is USED. Destructuring reads it at
                // import time and turns a legal cycle into a ReferenceError, which is what
                // execa's send.js ↔ strict.js pair hit.
                for ((src, alias) in bindings(named)) {
                    lines.add("const $alias = __esmBinding($temp, '$src');")
                }
            }
            val namespace = group(m, 3)
            if (namespace != null) lines.add("const $namespace = $temp;")
            lines.joinToString(" ")
        }
        // import 'mod'
        replace("""(?:^|(?<=[;}]))[ \t]*import\s*['"]([^'"]+)['"](?:\s*(?:with|assert)\s*\{[^}]*\})?\s*;?""") { m ->
            requireSettled(namedTemp(), group(m, 1)!!)
        }
        // export * as name from 'mod'   (ansi-escapes@7 re-exports its base this way — must run
        // before the bare `export * from` rule, whose pattern is a prefix of this)
        replace("""(?:^|(?<=[;}]))[ \t]*export\s*\*\s*as\s+([\w${'$'}]+)\s+from\s*['"]([^'"]+)['"]\s*;?""") { m ->
            val temp = namedTemp()
            requireSettled(temp, group(m, 2)!!) + " module.exports.${group(m, 1)!!} = $temp;"
        }
        // export * from 'mod' — star re-export excludes `default` and `__esModule` (spec
        // semantics — yoga-layout's `export * from './YGEnums.js'` must not clobber its own
        // default export).
        replace("""(?:^|(?<=[;}]))[ \t]*export\s*\*\s*from\s*['"]([^'"]+)['"]\s*;?""") { m ->
            val temp = namedTemp()
            requireSettled(temp, group(m, 1)!!) + " __reexportStar(module.exports, $temp);"
        }
        // export { a, b as c } from 'mod'
        replace("""(?:^|(?<=[;}]))[ \t]*export\s*\{([^}]*)\}\s*from\s*['"]([^'"]+)['"](?:\s*(?:with|assert)\s*\{[^}]*\})?\s*;?""") { m ->
            val temp = namedTemp()
            val lines = ArrayList<String>()
            lines.add(requireSettled(temp, group(m, 2)!!))
            for ((src, alias) in bindings(group(m, 1)!!)) {
                lines.add("__mouseLive(module.exports, '$alias', function(){ return $temp.$src; });")
            }
            lines.joinToString(" ")
        }
        // export { X as 'module.exports' } — the ES2022 string-named-export idiom that dual
        // CJS/ESM packages (yargs, cliui, y18n) use to make `require()` return X directly. Must
        // run BEFORE the general clause rule, whose `[^}]*` would swallow it and drop the alias.
        replace("""(?:^|(?<=[;}]))[ \t]*export\s*\{\s*([\w${'$'}]+)\s+as\s+['"]module\.exports['"]\s*\}\s*;?""") { m ->
            "module.exports = ${group(m, 1)!!};"
        }
        replace("""(?:^|(?<=[;}]))[ \t]*export\s*\{\s*([\w${'$'}]+)\s+as\s+['"]([^'"]+)['"]\s*\}\s*;?""") { m ->
            val name = group(m, 2)!!.replace("\\", "\\\\").replace("'", "\\'")
            "__mouseLive(module.exports, '$name', function(){ return ${group(m, 1)!!}; });"
        }
        // export { a, b as c };  — a trailing line comment must not defeat the match
        // (commander@15 ends one with "; // Deprecated").
        replace("""(?:^|(?<=[;}]))[ \t]*export\s*\{([^}]*)\}\s*;?\s*(//[^\n]*)?${'$'}""") { m ->
            bindings(group(m, 1)!!)
                .joinToString(" ") { "__mouseLive(module.exports, '${it.second}', function(){ return ${it.first}; });" }
        }
        // export default function name() / class Name — keep the declaration, alias at EOF.
        // Mid-line anchor: a preceding rule can leave `;export default` on one line when an
        // unterminated import (no semicolon, cliui) had its trailing newline consumed.
        replace("""(?:^|(?<=[;}]))[ \t]*export\s+default\s+(function\s*\*?\s+([\w${'$'}]+)|class\s+([\w${'$'}]+))""") { m ->
            val name = group(m, 2) ?: group(m, 3)!!
            prologue.add("__mouseLive(module.exports, 'default', function(){ return $name; });")
            group(m, 1)!!
        }
        // export default <expression>
        replace("""(?:^|(?<=[;}]))[ \t]*export\s+default\s+""") { "module.exports.default = " }
        // export const { a, b: c } = … / export const [x] = … — a destructuring declaration,
        // which signal-exit (under execa) uses, and which the NAME form below cannot match.
        replace("""(?:^|(?<=[;}]))[ \t]*export\s+(const|let|var)\s*(?=[{\[])""") { m ->
            val keyword = group(m, 1)!!
            val start = m.end()
            val masked = maskCache ?: text
            if (masked.length == text.length) {
                val (names, _) = destructuredNames(text, start, masked)
                for (name in names) {
                    prologue.add("__mouseLive(module.exports, '$name', function(){ return $name; });")
                }
            }
            "$keyword "
        }
        // The `*` is its own group because a generator is declared `function* name` — and
        // `export async function* _iterSSEMessages` is how the Anthropic SDK streams. Without it
        // the declaration kept its `export` keyword and the file would not parse.
        replace("""(?:^|(?<=[;}]))[ \t]*export\s+(const|let|var|class|function|async\s+function)(\s*\*)?\s+([\w${'$'}]+)""") { m ->
            val name = group(m, 3)!!
            prologue.add("__mouseLive(module.exports, '$name', function(){ return $name; });")
            "${group(m, 1)!!}${group(m, 2) ?: ""} $name"
        }

        // dynamic import() and import.meta, both code-only — see rewriteImportForms.
        val scanned = rewriteImportForms(text, meta = true)
        text = scanned.text
        // The whole of node's import.meta as one object, declared only where it is used.
        // __mouseFilename, not __filename: ESM files legitimately declare
        // `const __filename = fileURLToPath(import.meta.url)`, and substituting the param name
        // would make that line a TDZ self-reference (prettier's bundle).
        if (scanned.usedMeta) {
            text = "const __mouseImportMeta = { url: 'file://' + __mouseFilename, " +
                "filename: __mouseFilename, " +
                "dirname: __mouseFilename.replace(/[/][^/]*${'$'}/, '') || '/', " +
                "resolve: __mouseRequire.resolve };\n" + text
        }
        if (prologue.isNotEmpty()) text = prologue.joinToString("\n") + "\n" + text
        return text
    }

    /**
     * Does this source need the transpile? node decides by package type and extension; this is
     * the SYNTAX question underneath, and it is asked of the masked text so that an `import`
     * inside a string or a comment does not answer it.
     */
    fun looksLikeModule(source: String): Boolean {
        if (!source.contains("import") && !source.contains("export")) return false
        val masked = rewriteImportForms(source, meta = false, mask = true).text
        return STATEMENT_PROBE.matcher(masked).find()
    }

    /**
     * Does this module use TOP-LEVEL await — and therefore have to be evaluated asynchronously?
     *
     * This is the question node 22's `require(esm)` turns on. A module without top-level await is
     * finished the moment its body returns, so `require()` of it can hand back the real namespace;
     * one WITH top-level await genuinely is not finished, and node raises
     * `ERR_REQUIRE_ASYNC_MODULE` rather than pretend otherwise. Before this existed every ES module
     * was wrapped async, so `require('jose')` from a hand-written CommonJS file answered a PROMISE
     * and `Object.keys` of it was empty — the bug a real package found.
     *
     * ## What counts as "top level", and which way the errors fall
     *
     * An `await` is top-level when no ENCLOSING brace is a function body. Blocks do not matter —
     * `try { await x }` inside an async method is still inside that method — so the test is against
     * the whole stack rather than the nearest brace.
     *
     * A brace is treated as a function body when it follows `)` or `=>`. That deliberately catches
     * `if (…) {`, `for (…) {` and `catch (…) {` as well, and the imprecision is chosen rather than
     * tolerated, because the two mistakes are not equally bad:
     *
     *  - saying ASYNC when the module is sync would make `require()` of it throw, which is the very
     *    failure being fixed — so that direction must not happen for ordinary code, and method
     *    shorthand (`async foo() { await … }`, which every class-based package uses) is exactly
     *    what the `)` rule keeps out of it.
     *  - saying SYNC when the module has top-level await produces a SyntaxError from the engine at
     *    wrap time, and `node-host.js` catches it and re-wraps async. The emitted code is identical
     *    either way, which is what makes that fallback safe.
     *
     * So this errs toward sync, and the engine itself is the backstop for the cases it misses.
     */
    fun hasTopLevelAwait(source: String): Boolean {
        if (!source.contains("await")) return false
        val masked = rewriteImportForms(source, meta = false, mask = true).text
        // One entry per open brace: true when that brace opened a function body.
        val enclosing = ArrayList<Boolean>()
        // Brace depths at which a CONCISE arrow body is open — `async x => expr`, with no braces
        // at all. jose's `const handleJWK = async (…) => cached(…) ?? cached(…, await f(…))` is
        // exactly this, and a brace-only scan reads that `await` as top-level and refuses the
        // whole package. The body runs to the end of its statement, so the depth is popped at the
        // next `;` or when the enclosing brace closes.
        val concise = ArrayList<Int>()
        var pendingFunction = false
        var at = 0
        while (at < masked.length) {
            val ch = masked[at]
            when {
                // The mask blanks comments, templates and regexes but keeps QUOTED strings
                // verbatim on purpose — the import patterns have to read the specifier out of one.
                // So they are skipped here instead, or `const s = 'await f()'` reads as real code.
                ch == '\'' || ch == '"' -> {
                    val quote = ch
                    at += 1
                    while (at < masked.length) {
                        val inner = masked[at]
                        at += 1
                        if (inner == '\\') {
                            at += 1
                            continue
                        }
                        if (inner == quote || inner == '\n') break
                    }
                }
                ch == '{' -> {
                    enclosing.add(pendingFunction)
                    pendingFunction = false
                    at += 1
                }
                ch == '}' -> {
                    if (enclosing.isNotEmpty()) enclosing.removeAt(enclosing.size - 1)
                    while (concise.isNotEmpty() && concise.last() > enclosing.size) {
                        concise.removeAt(concise.size - 1)
                    }
                    at += 1
                }
                ch == ';' -> {
                    while (concise.isNotEmpty() && concise.last() >= enclosing.size) {
                        concise.removeAt(concise.size - 1)
                    }
                    at += 1
                }
                ch == '=' && at + 1 < masked.length && masked[at + 1] == '>' -> {
                    var probe = at + 2
                    while (probe < masked.length && masked[probe].isWhitespace()) probe += 1
                    if (probe < masked.length && masked[probe] == '{') {
                        pendingFunction = true
                    } else {
                        concise.add(enclosing.size)
                    }
                    at += 2
                }
                ch == ')' -> {
                    // Look ahead to the next non-space: a `{` there opens a body.
                    var probe = at + 1
                    while (probe < masked.length && masked[probe].isWhitespace()) probe += 1
                    if (probe < masked.length && masked[probe] == '{') pendingFunction = true
                    at += 1
                }
                ch.isLetter() || ch == '_' || ch == '$' -> {
                    var end = at
                    while (end < masked.length &&
                        (masked[end].isLetterOrDigit() || masked[end] == '_' || masked[end] == '$')
                    ) {
                        end += 1
                    }
                    val word = masked.substring(at, end)
                    // `obj.await` is a property and `{ await: 1 }` is a key — neither is the
                    // operator, and both appear in real code.
                    var after = end
                    while (after < masked.length && masked[after].isWhitespace()) after += 1
                    val member = (at > 0 && masked[at - 1] == '.') ||
                        (after < masked.length && masked[after] == ':')
                    if (word == "function") pendingFunction = true
                    if (word == "await" && !member && enclosing.none { it } && concise.isEmpty()) {
                        return true
                    }
                    at = end
                }
                else -> at += 1
            }
        }
        return false
    }

    private val STATEMENT_PROBE: Pattern = Pattern.compile(
        """(?:^|(?<=[;}]))[ \t]*(?:import\s*(?:[\w${'$'}{*'"]|\{)|export\s*(?:\{|\*|default\s|const\s|let\s|var\s|class\s|function\s|async\s+function\s))""",
        Pattern.MULTILINE,
    )
}
