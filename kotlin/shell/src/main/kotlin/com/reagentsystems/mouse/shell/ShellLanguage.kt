package com.reagentsystems.mouse.shell

/**
 * The msh LANGUAGE: lexer, AST, and parser — the difference between a command line and a shell.
 * [MouseShell] owns execution; this file owns structure, and contains no I/O and no state, so it
 * parses on any thread and verifies headlessly.
 *
 * A port of `swift/Mouse/ShellLanguage.swift`, kept structurally identical so the two shells can
 * be read side by side. The grammar is the POSIX shell subset real scripts are written in —
 * `if`/`for`/`while`/`until`/`case`, functions, `$(…)` and backticks, `$((…))` — deliberately not
 * bash-isms (no arrays, no process substitution). `&` job control stays refused until processes
 * are real.
 */

// MARK: - Words and tokens

sealed class ShellQuote {
    object None : ShellQuote()
    object Single : ShellQuote()
    object Double : ShellQuote()

    /**
     * `$(…)` or backticks: text is the inner source, executed at expansion time. [quoted]
     * remembers double-quote context — a quoted substitution never field-splits.
     */
    data class CommandSub(val quoted: Boolean) : ShellQuote()

    /** `$((…))`: text is the arithmetic expression. */
    data class Arithmetic(val quoted: Boolean) : ShellQuote()
}

/**
 * A word is segments with their quoting, so expansion can respect it: single quotes are literal,
 * double quotes expand variables but never glob or field-split, bare text does all three.
 */
data class ShellWordPart(val text: String, val quote: ShellQuote)

typealias ShellWord = List<ShellWordPart>

sealed class ShellToken {
    data class Word(val parts: ShellWord) : ShellToken()

    /** `|  ;  ;;  &&  ||  >  >>  <  (  )` */
    data class Op(val value: String) : ShellToken()

    object Newline : ShellToken()
}

/**
 * [incomplete] is true when the source simply ended too soon (unclosed quote, missing `fi`) — the
 * prompt uses it to ask for a continuation line instead of erroring.
 */
class ShellParseError(message: String, val incomplete: Boolean = false) : Exception(message)

// MARK: - Lexer

object ShellLexer {

    fun lex(source: String): List<ShellToken> = Scanner(source).run()

    private class Scanner(source: String) {
        private val chars = source.toCharArray()
        private var i = 0

        private val tokens = ArrayList<ShellToken>()
        private var parts = ArrayList<ShellWordPart>()
        private val current = StringBuilder()
        private var quote: ShellQuote = ShellQuote.None

        /** For comment detection: `#` opens a comment only at the start of a word. */
        private var atWordStart = true

        private fun flushSegment() {
            if (current.isNotEmpty() || quote != ShellQuote.None) {
                parts.add(ShellWordPart(current.toString(), quote))
                current.setLength(0)
            }
        }

        private fun flushWord() {
            flushSegment()
            if (parts.isNotEmpty()) {
                tokens.add(ShellToken.Word(parts))
                parts = ArrayList()
            }
            atWordStart = true
        }

        /**
         * Scan from an opening delimiter to its match, honoring quotes; returns the inner text.
         * `(`/`)` nest; backticks don't.
         */
        private fun scanBalanced(open: Char, close: Char): String {
            var depth = 1
            val inner = StringBuilder()
            var innerQuote: Char? = null
            while (i < chars.size) {
                val c = chars[i]
                val q = innerQuote
                if (q != null) {
                    if (c == q) innerQuote = null
                    if (c == '\\' && q == '"' && i + 1 < chars.size) {
                        inner.append(c); i++
                        inner.append(chars[i]); i++
                        continue
                    }
                    inner.append(c); i++
                    continue
                }
                if (c == '\'' || c == '"') { innerQuote = c; inner.append(c); i++; continue }
                if (c == open && open != close) depth++
                if (c == close) {
                    depth--
                    if (depth == 0) { i++; return inner.toString() }
                }
                inner.append(c)
                i++
            }
            throw ShellParseError("unclosed $open", incomplete = true)
        }

        /** `${…}` stays verbatim in the word; the expander re-parses it. Shared by both states. */
        private fun consumeBracedVerbatim() {
            current.append('$'); current.append('{')
            i += 2
            var depth = 1
            while (i < chars.size && depth > 0) {
                if (chars[i] == '{') depth++
                if (chars[i] == '}') depth--
                current.append(chars[i])
                i++
            }
            if (depth != 0) throw ShellParseError("unclosed \${", incomplete = true)
        }

        /** `$(` already seen at [i]-2: either `$((arith))` or `$(command)`. */
        private fun consumeSubstitution(quoted: Boolean) {
            if (i < chars.size && chars[i] == '(') {
                i++
                val inner = scanBalanced('(', ')')
                if (i >= chars.size || chars[i] != ')') throw ShellParseError("unclosed \$((", incomplete = true)
                i++
                parts.add(ShellWordPart(inner, ShellQuote.Arithmetic(quoted)))
            } else {
                val inner = scanBalanced('(', ')')
                parts.add(ShellWordPart(inner, ShellQuote.CommandSub(quoted)))
            }
        }

        fun run(): List<ShellToken> {
            while (i < chars.size) {
                val ch = chars[i]
                when (quote) {
                    // `quote` only ever holds none/single/double; substitutions are captured whole
                    // by scanBalanced and never become the scanning state.
                    is ShellQuote.CommandSub, is ShellQuote.Arithmetic ->
                        throw ShellParseError("lexer state corrupted")

                    is ShellQuote.Single -> {
                        if (ch == '\'') {
                            parts.add(ShellWordPart(current.toString(), ShellQuote.Single))
                            current.setLength(0)
                            quote = ShellQuote.None
                        } else {
                            current.append(ch)
                        }
                        i++
                    }

                    is ShellQuote.Double -> when {
                        ch == '"' -> {
                            parts.add(ShellWordPart(current.toString(), ShellQuote.Double))
                            current.setLength(0)
                            quote = ShellQuote.None
                            i++
                        }
                        ch == '\\' && i + 1 < chars.size && chars[i + 1] in "\"\\\$`" -> {
                            current.append(chars[i + 1]); i += 2
                        }
                        ch == '$' && i + 1 < chars.size && chars[i + 1] == '(' -> {
                            // $( … ) inside double quotes: capture, keep surrounding text quoted.
                            if (current.isNotEmpty()) {
                                parts.add(ShellWordPart(current.toString(), ShellQuote.Double))
                                current.setLength(0)
                            }
                            i += 2
                            consumeSubstitution(quoted = true)
                        }
                        ch == '$' && i + 1 < chars.size && chars[i + 1] == '{' -> consumeBracedVerbatim()
                        ch == '`' -> {
                            if (current.isNotEmpty()) {
                                parts.add(ShellWordPart(current.toString(), ShellQuote.Double))
                                current.setLength(0)
                            }
                            i++
                            parts.add(ShellWordPart(scanBalanced('`', '`'), ShellQuote.CommandSub(true)))
                        }
                        else -> { current.append(ch); i++ }
                    }

                    is ShellQuote.None -> when {
                        ch == '\'' -> { flushSegment(); quote = ShellQuote.Single; atWordStart = false; i++ }
                        ch == '"' -> { flushSegment(); quote = ShellQuote.Double; atWordStart = false; i++ }
                        ch == '\\' -> {
                            if (i + 1 >= chars.size) throw ShellParseError("trailing backslash", incomplete = true)
                            if (chars[i + 1] == '\n') { i += 2; continue }   // line continuation
                            flushSegment()
                            parts.add(ShellWordPart(chars[i + 1].toString(), ShellQuote.Single))
                            atWordStart = false
                            i += 2
                        }
                        ch == '#' && atWordStart && current.isEmpty() && parts.isEmpty() -> {
                            while (i < chars.size && chars[i] != '\n') i++
                        }
                        ch == ' ' || ch == '\t' -> { flushWord(); i++ }
                        ch == '\n' -> { flushWord(); tokens.add(ShellToken.Newline); i++ }
                        ch == '$' && i + 1 < chars.size && chars[i + 1] == '(' -> {
                            flushSegment()
                            atWordStart = false
                            i += 2
                            consumeSubstitution(quoted = false)
                        }
                        ch == '$' && i + 1 < chars.size && chars[i + 1] == '{' -> {
                            // It may hold nested $(…), which must not be captured out of context.
                            atWordStart = false
                            consumeBracedVerbatim()
                        }
                        ch == '`' -> {
                            flushSegment()
                            atWordStart = false
                            i++
                            parts.add(ShellWordPart(scanBalanced('`', '`'), ShellQuote.CommandSub(false)))
                        }
                        ch == '|' || ch == ';' || ch == '<' || ch == '>' || ch == '&' || ch == '(' || ch == ')' -> {
                            flushWord()
                            val next = if (i + 1 < chars.size) chars[i + 1] else ' '
                            when {
                                ch == '&' && next == '&' -> { tokens.add(ShellToken.Op("&&")); i += 2 }
                                ch == '|' && next == '|' -> { tokens.add(ShellToken.Op("||")); i += 2 }
                                ch == '>' && next == '>' -> { tokens.add(ShellToken.Op(">>")); i += 2 }
                                ch == ';' && next == ';' -> { tokens.add(ShellToken.Op(";;")); i += 2 }
                                // This used to say processes "arrive with the wasm runtime". They
                                // arrived — `pkg install python` runs CPython — and `&` still does
                                // not work, so the old reason had stopped being true. The real
                                // one: msh runs one command at a time, and a running program holds
                                // the terminal until a keypress stops it.
                                ch == '&' -> throw ShellParseError(
                                    "no job control (&) — msh runs one command at a time; a running " +
                                        "program holds the terminal until a keypress stops it",
                                )
                                else -> { tokens.add(ShellToken.Op(ch.toString())); i++ }
                            }
                        }
                        else -> { current.append(ch); atWordStart = false; i++ }
                    }
                }
            }
            if (quote != ShellQuote.None) throw ShellParseError("unclosed quote", incomplete = true)
            flushWord()
            return tokens
        }
    }
}

// MARK: - AST

class ShellRedirect(val kind: Kind, val target: ShellWord) {
    enum class Kind { STDOUT_WRITE, STDOUT_APPEND, STDIN_READ }
}

sealed class ShellNode {
    /** Statements run in order; `&&`/`||` chains are their own node. */
    data class Sequence(val nodes: List<ShellNode>) : ShellNode()

    data class AndOr(val first: ShellNode, val rest: List<Pair<String, ShellNode>>) : ShellNode()

    data class Pipeline(val commands: List<ShellNode>, val negated: Boolean) : ShellNode()

    data class Simple(
        val assignments: List<Pair<String, ShellWord>>,
        val words: List<ShellWord>,
        val redirects: List<ShellRedirect>,
    ) : ShellNode()

    data class IfClause(
        val branches: List<Pair<ShellNode, ShellNode>>,
        val elseBody: ShellNode?,
    ) : ShellNode()

    /** `until` is `while` with the condition inverted. */
    data class WhileClause(
        val condition: ShellNode,
        val body: ShellNode,
        val until: Boolean,
        val redirects: List<ShellRedirect>,
    ) : ShellNode()

    /** Null [words] = `"$@"` (POSIX default). */
    data class ForClause(
        val variable: String,
        val words: List<ShellWord>?,
        val body: ShellNode,
        val redirects: List<ShellRedirect>,
    ) : ShellNode()

    data class CaseClause(val subject: ShellWord, val items: List<Item>) : ShellNode() {
        class Item(val patterns: List<ShellWord>, val body: ShellNode)
    }

    data class FunctionDef(val name: String, val body: ShellNode) : ShellNode()

    data class BraceGroup(val body: ShellNode, val redirects: List<ShellRedirect>) : ShellNode()
}

// MARK: - Parser

class ShellParser(private val tokens: List<ShellToken>) {
    private var index = 0

    companion object {
        fun parse(source: String): ShellNode = ShellParser(ShellLexer.lex(source)).parseProgram()

        private val KEYWORDS = setOf(
            "if", "then", "elif", "else", "fi", "for", "while", "until", "do", "done",
            "case", "esac", "in", "{", "}", "!",
        )
    }

    // -- token helpers --------------------------------------------------------

    private val peek: ShellToken? get() = tokens.getOrNull(index)

    private fun advance(): ShellToken? = tokens.getOrNull(index)?.also { index++ }

    private fun skipNewlines() {
        while (peek is ShellToken.Newline) index++
    }

    private fun skipSeparators() {
        while (true) {
            val token = peek
            if (token is ShellToken.Newline) { index++; continue }
            if (token is ShellToken.Op && token.value == ";") { index++; continue }
            break
        }
    }

    /**
     * The word's literal text when it is a single unquoted segment — how keywords are recognized.
     * `"if"` (quoted) is an argument, `if` is a keyword.
     */
    private fun literal(token: ShellToken?): String? {
        if (token !is ShellToken.Word) return null
        val parts = token.parts
        if (parts.size != 1 || parts[0].quote != ShellQuote.None) return null
        return parts[0].text
    }

    private fun expectKeyword(keyword: String) {
        skipSeparators()
        if (literal(peek) != keyword) {
            throw ShellParseError("expected '$keyword'", incomplete = peek == null)
        }
        index++
    }

    private fun isOp(token: ShellToken?, value: String) = token is ShellToken.Op && token.value == value

    // -- grammar ----------------------------------------------------------------

    fun parseProgram(): ShellNode {
        val list = parseList(emptySet())
        skipSeparators()
        val token = peek
        if (token != null) {
            if (token is ShellToken.Op) throw ShellParseError("unexpected '${token.value}'")
            throw ShellParseError("unexpected '${literal(token) ?: "token"}'")
        }
        return list
    }

    /** A sequence of and-or chains, ended by EOF or a keyword in [stoppers] (left unconsumed). */
    private fun parseList(stoppers: Set<String>): ShellNode {
        val nodes = ArrayList<ShellNode>()
        while (true) {
            skipSeparators()
            val token = peek ?: break
            if (isOp(token, ")") || isOp(token, ";;")) break
            val word = literal(token)
            if (word != null && stoppers.contains(word)) break
            nodes.add(parseAndOr())
        }
        return ShellNode.Sequence(nodes)
    }

    private fun parseAndOr(): ShellNode {
        val first = parsePipeline()
        val rest = ArrayList<Pair<String, ShellNode>>()
        while (true) {
            val token = peek
            if (token !is ShellToken.Op || (token.value != "&&" && token.value != "||")) break
            index++
            skipNewlines()
            rest.add(token.value to parsePipeline())
        }
        if (rest.isEmpty()) return first
        return ShellNode.AndOr(first, rest)
    }

    private fun parsePipeline(): ShellNode {
        var negated = false
        if (literal(peek) == "!") { negated = true; index++ }
        val commands = arrayListOf(parseCommand())
        while (isOp(peek, "|")) {
            index++
            skipNewlines()
            commands.add(parseCommand())
        }
        if (commands.size == 1 && !negated) return commands[0]
        return ShellNode.Pipeline(commands, negated)
    }

    private fun parseCommand(): ShellNode {
        skipNewlines()
        val token = peek ?: throw ShellParseError("expected a command", incomplete = true)
        return when (val word = literal(token)) {
            "if" -> parseIf()
            "while" -> parseWhile(until = false)
            "until" -> parseWhile(until = true)
            "for" -> parseFor()
            "case" -> parseCase()
            "{" -> parseBraceGroup()
            "then", "else", "elif", "fi", "do", "done", "esac" ->
                throw ShellParseError("unexpected '$word'")
            else -> parseSimpleOrFunction()
        }
    }

    private fun parseIf(): ShellNode {
        index++   // 'if'
        val branches = ArrayList<Pair<ShellNode, ShellNode>>()
        val condition = parseList(setOf("then"))
        expectKeyword("then")
        branches.add(condition to parseList(setOf("elif", "else", "fi")))
        var elseBody: ShellNode? = null
        while (true) {
            skipSeparators()
            when (literal(peek)) {
                "elif" -> {
                    index++
                    val elifCondition = parseList(setOf("then"))
                    expectKeyword("then")
                    branches.add(elifCondition to parseList(setOf("elif", "else", "fi")))
                }
                "else" -> {
                    index++
                    elseBody = parseList(setOf("fi"))
                }
                "fi" -> {
                    index++
                    val node = ShellNode.IfClause(branches, elseBody)
                    val redirects = parseTrailingRedirects()
                    return if (redirects.isEmpty()) node else ShellNode.BraceGroup(node, redirects)
                }
                else -> throw ShellParseError("expected 'fi'", incomplete = peek == null)
            }
        }
    }

    private fun parseWhile(until: Boolean): ShellNode {
        index++
        val condition = parseList(setOf("do"))
        expectKeyword("do")
        val body = parseList(setOf("done"))
        expectKeyword("done")
        return ShellNode.WhileClause(condition, body, until, parseTrailingRedirects())
    }

    private fun parseFor(): ShellNode {
        index++
        val name = literal(advance())
        if (name == null || !isName(name)) throw ShellParseError("for: expected a variable name")
        var words: List<ShellWord>? = null
        skipNewlines()
        if (literal(peek) == "in") {
            index++
            val collected = ArrayList<ShellWord>()
            while (true) {
                val token = peek
                if (token !is ShellToken.Word) break
                collected.add(token.parts)
                index++
            }
            words = collected
        }
        expectKeyword("do")
        val body = parseList(setOf("done"))
        expectKeyword("done")
        return ShellNode.ForClause(name, words, body, parseTrailingRedirects())
    }

    private fun parseCase(): ShellNode {
        index++
        val subjectToken = advance()
        if (subjectToken !is ShellToken.Word) throw ShellParseError("case: expected a word")
        expectKeyword("in")
        val items = ArrayList<ShellNode.CaseClause.Item>()
        while (true) {
            skipSeparators()
            if (literal(peek) == "esac") { index++; break }
            if (peek == null) throw ShellParseError("expected 'esac'", incomplete = true)
            if (isOp(peek, "(")) index++   // optional leading (
            val patterns = ArrayList<ShellWord>()
            while (true) {
                val pattern = advance()
                if (pattern !is ShellToken.Word) {
                    throw ShellParseError("case: expected a pattern", incomplete = peek == null)
                }
                patterns.add(pattern.parts)
                if (isOp(peek, "|")) { index++; continue }
                break
            }
            if (!isOp(advance(), ")")) throw ShellParseError("case: expected ')'")
            items.add(ShellNode.CaseClause.Item(patterns, parseList(setOf("esac"))))
            if (isOp(peek, ";;")) index++
        }
        val node = ShellNode.CaseClause(subjectToken.parts, items)
        val redirects = parseTrailingRedirects()
        return if (redirects.isEmpty()) node else ShellNode.BraceGroup(node, redirects)
    }

    private fun parseBraceGroup(): ShellNode {
        index++   // '{'
        val body = parseList(setOf("}"))
        expectKeyword("}")
        return ShellNode.BraceGroup(body, parseTrailingRedirects())
    }

    /** `NAME() body`, or a plain command: assignments, words, redirects. */
    private fun parseSimpleOrFunction(): ShellNode {
        // Function definition: NAME ( ) command
        val name = literal(peek)
        if (name != null && isName(name) && !KEYWORDS.contains(name) &&
            index + 2 < tokens.size && isOp(tokens[index + 1], "(") && isOp(tokens[index + 2], ")")
        ) {
            index += 3
            skipNewlines()
            return ShellNode.FunctionDef(name, parseCommand())
        }

        val assignments = ArrayList<Pair<String, ShellWord>>()
        val words = ArrayList<ShellWord>()
        val redirects = ArrayList<ShellRedirect>()
        loop@ while (true) {
            val token = peek ?: break
            when {
                token is ShellToken.Word -> {
                    // NAME=value before the command name is an assignment.
                    val assignment = if (words.isEmpty()) splitAssignment(token.parts) else null
                    if (assignment != null) assignments.add(assignment) else words.add(token.parts)
                    index++
                }
                token is ShellToken.Op && (token.value == ">" || token.value == ">>" || token.value == "<") -> {
                    index++
                    val target = advance()
                    if (target !is ShellToken.Word) {
                        throw ShellParseError("redirect needs a target", incomplete = peek == null)
                    }
                    redirects.add(ShellRedirect(redirectKind(token.value), target.parts))
                }
                else -> break@loop
            }
        }
        if (assignments.isEmpty() && words.isEmpty() && redirects.isEmpty()) {
            throw ShellParseError("expected a command")
        }
        return ShellNode.Simple(assignments, words, redirects)
    }

    private fun parseTrailingRedirects(): List<ShellRedirect> {
        val redirects = ArrayList<ShellRedirect>()
        while (true) {
            val token = peek
            if (token !is ShellToken.Op || (token.value != ">" && token.value != ">>" && token.value != "<")) break
            index++
            val target = advance()
            if (target !is ShellToken.Word) {
                throw ShellParseError("redirect needs a target", incomplete = peek == null)
            }
            redirects.add(ShellRedirect(redirectKind(token.value), target.parts))
        }
        return redirects
    }

    private fun redirectKind(op: String) = when (op) {
        ">" -> ShellRedirect.Kind.STDOUT_WRITE
        ">>" -> ShellRedirect.Kind.STDOUT_APPEND
        else -> ShellRedirect.Kind.STDIN_READ
    }

    private fun splitAssignment(parts: ShellWord): Pair<String, ShellWord>? {
        val first = parts.firstOrNull() ?: return null
        if (first.quote != ShellQuote.None) return null
        val equals = first.text.indexOf('=')
        if (equals < 0) return null
        val name = first.text.substring(0, equals)
        if (!isName(name)) return null
        val value = ArrayList<ShellWordPart>()
        val rest = first.text.substring(equals + 1)
        if (rest.isNotEmpty()) value.add(ShellWordPart(rest, ShellQuote.None))
        value.addAll(parts.drop(1))
        return name to value
    }

    private fun isName(text: String): Boolean = text.isNotEmpty() &&
        (text[0].isLetter() || text[0] == '_') &&
        text.all { it.isLetter() || it.isDigit() || it == '_' }
}

// MARK: - Patterns (fnmatch)

/**
 * POSIX `fnmatch` with no flags, which is what `Shell.swift` calls: `*` matches any run INCLUDING
 * `/` (no FNM_PATHNAME), `?` matches one character, `[…]` is a bracket expression with ranges and
 * `!`/`^` negation, and `\` escapes.
 *
 * The slash mattering is not academic: the longest-prefix strip that turns `/usr/local/bin/tool`
 * into `tool` only works because `*` is allowed to eat the separators.
 */
object ShellPattern {

    fun matches(pattern: String, text: String): Boolean {
        var p = 0
        var s = 0
        // Backtracking point for the most recent `*`: on a dead end, give the star one more
        // character and retry. Linear in practice and never recurses.
        var starPattern = -1
        var starText = -1

        while (s < text.length) {
            if (p < pattern.length) {
                val pc = pattern[p]
                if (pc == '\\' && p + 1 < pattern.length) {
                    if (text[s] == pattern[p + 1]) { p += 2; s++; continue }
                } else if (pc == '?') {
                    p++; s++; continue
                } else if (pc == '*') {
                    starPattern = p; starText = s; p++; continue
                } else if (pc == '[') {
                    val end = bracketEnd(pattern, p)
                    if (end > 0) {
                        if (bracketMatches(pattern, p, end, text[s])) { p = end + 1; s++; continue }
                    } else if (text[s] == '[') {
                        p++; s++; continue
                    }
                } else if (pc == text[s]) {
                    p++; s++; continue
                }
            }
            if (starPattern >= 0) {
                starText++
                s = starText
                p = starPattern + 1
                continue
            }
            return false
        }
        while (p < pattern.length && pattern[p] == '*') p++
        return p == pattern.length
    }

    /** Index of the `]` closing the bracket opened at [start], or -1 when there is none. */
    private fun bracketEnd(pattern: String, start: Int): Int {
        var i = start + 1
        if (i < pattern.length && (pattern[i] == '!' || pattern[i] == '^')) i++
        if (i < pattern.length && pattern[i] == ']') i++   // a leading ] is literal
        while (i < pattern.length && pattern[i] != ']') i++
        return if (i < pattern.length) i else -1
    }

    private fun bracketMatches(pattern: String, start: Int, end: Int, c: Char): Boolean {
        var i = start + 1
        var negate = false
        if (i < end && (pattern[i] == '!' || pattern[i] == '^')) { negate = true; i++ }
        var hit = false
        while (i < end) {
            if (i + 2 < end && pattern[i + 1] == '-') {
                if (c >= pattern[i] && c <= pattern[i + 2]) hit = true
                i += 3
            } else {
                if (pattern[i] == c) hit = true
                i++
            }
        }
        return hit != negate
    }
}

// MARK: - Arithmetic ($((…)))

/**
 * Integer arithmetic with variables: `+ - * / %`, comparisons, `&& || !`, parentheses, unary
 * minus. Variables resolve through the lookup the shell provides (bare `x` or `$x`).
 */
object ShellArithmetic {

    fun evaluate(expression: String, lookup: (String) -> String?): Long {
        val parser = Parser(expression, lookup)
        val value = parser.parseOr()
        parser.skipSpaces()
        if (!parser.atEnd) throw ShellParseError("arithmetic: trailing garbage in '$expression'")
        return value
    }

    private class Parser(expression: String, val lookup: (String) -> String?) {
        val chars = expression.toCharArray()
        var index = 0

        val atEnd: Boolean get() = index >= chars.size

        fun skipSpaces() {
            while (index < chars.size && (chars[index] == ' ' || chars[index] == '\t' || chars[index] == '\n')) index++
        }

        fun match(text: String): Boolean {
            skipSpaces()
            if (index + text.length > chars.size) return false
            for (offset in text.indices) if (chars[index + offset] != text[offset]) return false
            // Don't take '<' when it's '<=' etc.
            if ((text == "<" || text == ">") && index + 1 < chars.size && chars[index + 1] == '=') return false
            if (text == "&" || text == "|") return false
            index += text.length
            return true
        }

        fun parseOr(): Long {
            var left = parseAnd()
            while (match("||")) { val right = parseAnd(); left = if (left != 0L || right != 0L) 1L else 0L }
            return left
        }

        fun parseAnd(): Long {
            var left = parseComparison()
            while (match("&&")) { val right = parseComparison(); left = if (left != 0L && right != 0L) 1L else 0L }
            return left
        }

        fun parseComparison(): Long {
            var left = parseAdditive()
            while (true) {
                left = when {
                    match("==") -> if (left == parseAdditive()) 1L else 0L
                    match("!=") -> if (left != parseAdditive()) 1L else 0L
                    match("<=") -> if (left <= parseAdditive()) 1L else 0L
                    match(">=") -> if (left >= parseAdditive()) 1L else 0L
                    match("<") -> if (left < parseAdditive()) 1L else 0L
                    match(">") -> if (left > parseAdditive()) 1L else 0L
                    else -> return left
                }
            }
        }

        fun parseAdditive(): Long {
            var left = parseMultiplicative()
            while (true) {
                when {
                    match("+") -> left += parseMultiplicative()
                    match("-") -> left -= parseMultiplicative()
                    else -> return left
                }
            }
        }

        fun parseMultiplicative(): Long {
            var left = parseUnary()
            while (true) {
                when {
                    match("*") -> left *= parseUnary()
                    match("/") -> {
                        val right = parseUnary()
                        if (right == 0L) throw ShellParseError("arithmetic: division by zero")
                        left /= right
                    }
                    match("%") -> {
                        val right = parseUnary()
                        if (right == 0L) throw ShellParseError("arithmetic: division by zero")
                        left %= right
                    }
                    else -> return left
                }
            }
        }

        fun parseUnary(): Long {
            skipSpaces()
            if (match("!")) return if (parseUnary() == 0L) 1L else 0L
            if (match("-")) return -parseUnary()
            if (match("+")) return parseUnary()
            if (match("(")) {
                val value = parseOr()
                skipSpaces()
                if (!match(")")) throw ShellParseError("arithmetic: expected ')'")
                return value
            }
            return parseAtom()
        }

        fun parseAtom(): Long {
            skipSpaces()
            if (index >= chars.size) throw ShellParseError("arithmetic: expected a value")
            var ch = chars[index]
            var isParameter = false
            if (ch == '$') {
                // `$1`, `$x`: always a parameter lookup — `$1 + $2` are positionals, not digits.
                isParameter = true
                index++
                if (index >= chars.size) throw ShellParseError("arithmetic: bad $")
                ch = chars[index]
            }
            if (ch.isDigit()) {
                val digits = StringBuilder()
                while (index < chars.size && chars[index].isDigit()) { digits.append(chars[index]); index++ }
                if (isParameter) return lookup(digits.toString())?.toLongOrNull() ?: 0L
                return digits.toString().toLongOrNull() ?: 0L
            }
            if (ch.isLetter() || ch == '_') {
                val name = StringBuilder()
                while (index < chars.size && (chars[index].isLetter() || chars[index].isDigit() || chars[index] == '_')) {
                    name.append(chars[index]); index++
                }
                return lookup(name.toString())?.toLongOrNull() ?: 0L
            }
            throw ShellParseError("arithmetic: unexpected '$ch'")
        }
    }
}
