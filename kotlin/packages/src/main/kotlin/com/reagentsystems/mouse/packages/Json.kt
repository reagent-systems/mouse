package com.reagentsystems.mouse.packages

/**
 * The JSON this module needs, hand-written.
 *
 * iOS reads registry documents with Foundation's `JSONSerialization`; the Android app reads its
 * own with `org.json`. Neither is available here: `org.json` ships inside the Android framework,
 * not the JDK, so a pure Kotlin/JVM module that wanted it would need a third-party artifact
 * (invariant #4) and would stop building off-device. So this is the same disposition the project
 * already takes with tar, gzip and git — write the small thing.
 *
 * Values map onto Kotlin natives the way `JSONSerialization` maps onto Swift's, so the port of
 * `PackageManager.swift` reads the same shape: object → `Map<String, Any?>`, array →
 * `List<Any?>`, string → `String`, number → `Long` or `Double`, `true`/`false` → `Boolean`,
 * `null` → `null`.
 */
object Json {

    class ParseError(message: String) : Exception(message)

    fun parse(text: String): Any? {
        val parser = Parser(text)
        parser.skipWhitespace()
        val value = parser.parseValue()
        parser.skipWhitespace()
        if (!parser.atEnd) throw ParseError("trailing content at offset ${parser.index}")
        return value
    }

    /** Parse, and answer null rather than throwing when the text is not a JSON object. */
    fun parseObjectOrNull(text: String): Map<String, Any?>? =
        runCatching { parse(text) }.getOrNull().asObject()

    /**
     * Serialize. Keys are ALWAYS sorted, matching the `.sortedKeys` the Swift side writes its
     * manifest and package.json with — a manifest that reorders itself on every install is a
     * diff nobody can read.
     */
    fun write(value: Any?, pretty: Boolean = false): String {
        val out = StringBuilder()
        writeValue(value, out, pretty, 0)
        return out.toString()
    }

    // MARK: - Reading

    private class Parser(private val text: String) {
        var index = 0
        val atEnd: Boolean get() = index >= text.length

        fun skipWhitespace() {
            while (index < text.length) {
                when (text[index]) {
                    ' ', '\t', '\n', '\r' -> index += 1
                    else -> return
                }
            }
        }

        fun parseValue(): Any? {
            if (atEnd) throw ParseError("unexpected end of input")
            return when (val c = text[index]) {
                '{' -> parseObject()
                '[' -> parseArray()
                '"' -> parseString()
                't' -> literal("true", true)
                'f' -> literal("false", false)
                'n' -> literal("null", null)
                else -> {
                    if (c == '-' || c in '0'..'9') parseNumber()
                    else throw ParseError("unexpected '$c' at offset $index")
                }
            }
        }

        private fun literal(word: String, value: Any?): Any? {
            if (!text.startsWith(word, index)) throw ParseError("bad literal at offset $index")
            index += word.length
            return value
        }

        private fun expect(c: Char) {
            skipWhitespace()
            if (atEnd || text[index] != c) throw ParseError("expected '$c' at offset $index")
            index += 1
        }

        private fun parseObject(): Map<String, Any?> {
            index += 1 // '{'
            // LinkedHashMap: document order is preserved on read. Writing sorts explicitly.
            val map = LinkedHashMap<String, Any?>()
            skipWhitespace()
            if (!atEnd && text[index] == '}') { index += 1; return map }
            while (true) {
                skipWhitespace()
                val key = parseString()
                expect(':')
                skipWhitespace()
                map[key] = parseValue()
                skipWhitespace()
                if (atEnd) throw ParseError("unterminated object")
                when (text[index]) {
                    ',' -> index += 1
                    '}' -> { index += 1; return map }
                    else -> throw ParseError("expected ',' or '}' at offset $index")
                }
            }
        }

        private fun parseArray(): List<Any?> {
            index += 1 // '['
            val list = ArrayList<Any?>()
            skipWhitespace()
            if (!atEnd && text[index] == ']') { index += 1; return list }
            while (true) {
                skipWhitespace()
                list.add(parseValue())
                skipWhitespace()
                if (atEnd) throw ParseError("unterminated array")
                when (text[index]) {
                    ',' -> index += 1
                    ']' -> { index += 1; return list }
                    else -> throw ParseError("expected ',' or ']' at offset $index")
                }
            }
        }

        private fun parseString(): String {
            if (atEnd || text[index] != '"') throw ParseError("expected a string at offset $index")
            index += 1
            val out = StringBuilder()
            while (true) {
                if (atEnd) throw ParseError("unterminated string")
                when (val c = text[index]) {
                    '"' -> { index += 1; return out.toString() }
                    '\\' -> {
                        index += 1
                        if (atEnd) throw ParseError("unterminated escape")
                        when (val escape = text[index]) {
                            '"' -> out.append('"')
                            '\\' -> out.append('\\')
                            '/' -> out.append('/')
                            'b' -> out.append('\b')
                            'f' -> out.append('\u000C')
                            'n' -> out.append('\n')
                            'r' -> out.append('\r')
                            't' -> out.append('\t')
                            'u' -> {
                                if (index + 4 >= text.length) throw ParseError("truncated \\u escape")
                                val hex = text.substring(index + 1, index + 5)
                                val code = hex.toIntOrNull(16) ?: throw ParseError("bad \\u escape '$hex'")
                                // Surrogate pairs need no special handling: each half is its own
                                // \u escape and Kotlin strings are UTF-16 already.
                                out.append(code.toChar())
                                index += 4
                            }
                            else -> throw ParseError("bad escape '\\$escape'")
                        }
                        index += 1
                    }
                    else -> { out.append(c); index += 1 }
                }
            }
        }

        private fun parseNumber(): Any {
            val start = index
            if (!atEnd && text[index] == '-') index += 1
            while (!atEnd && text[index] in '0'..'9') index += 1
            var floating = false
            if (!atEnd && text[index] == '.') {
                floating = true
                index += 1
                while (!atEnd && text[index] in '0'..'9') index += 1
            }
            if (!atEnd && (text[index] == 'e' || text[index] == 'E')) {
                floating = true
                index += 1
                if (!atEnd && (text[index] == '+' || text[index] == '-')) index += 1
                while (!atEnd && text[index] in '0'..'9') index += 1
            }
            val slice = text.substring(start, index)
            if (!floating) slice.toLongOrNull()?.let { return it }
            return slice.toDoubleOrNull() ?: throw ParseError("bad number '$slice'")
        }
    }

    // MARK: - Writing

    private fun writeValue(value: Any?, out: StringBuilder, pretty: Boolean, depth: Int) {
        when (value) {
            null -> out.append("null")
            is String -> writeString(value, out)
            is Boolean -> out.append(if (value) "true" else "false")
            is Int, is Long -> out.append(value.toString())
            is Double, is Float -> {
                val d = (value as Number).toDouble()
                // Whole numbers print without the ".0" tail, matching what both platforms emit.
                if (d == d.toLong().toDouble()) out.append(d.toLong().toString()) else out.append(d.toString())
            }
            is Map<*, *> -> writeObject(value, out, pretty, depth)
            is Iterable<*> -> writeArray(value, out, pretty, depth)
            else -> writeString(value.toString(), out)
        }
    }

    private fun writeObject(map: Map<*, *>, out: StringBuilder, pretty: Boolean, depth: Int) {
        val entries = map.entries.sortedBy { it.key.toString() }
        if (entries.isEmpty()) { out.append("{}"); return }
        out.append('{')
        entries.forEachIndexed { i, entry ->
            if (i > 0) out.append(',')
            newline(out, pretty, depth + 1)
            writeString(entry.key.toString(), out)
            out.append(':')
            if (pretty) out.append(' ')
            writeValue(entry.value, out, pretty, depth + 1)
        }
        newline(out, pretty, depth)
        out.append('}')
    }

    private fun writeArray(items: Iterable<*>, out: StringBuilder, pretty: Boolean, depth: Int) {
        val list = items.toList()
        if (list.isEmpty()) { out.append("[]"); return }
        out.append('[')
        list.forEachIndexed { i, item ->
            if (i > 0) out.append(',')
            newline(out, pretty, depth + 1)
            writeValue(item, out, pretty, depth + 1)
        }
        newline(out, pretty, depth)
        out.append(']')
    }

    private fun newline(out: StringBuilder, pretty: Boolean, depth: Int) {
        if (!pretty) return
        out.append('\n')
        repeat(depth) { out.append("  ") }
    }

    private fun writeString(text: String, out: StringBuilder) {
        out.append('"')
        for (c in text) {
            when (c) {
                '"' -> out.append("\\\"")
                '\\' -> out.append("\\\\")
                '\n' -> out.append("\\n")
                '\r' -> out.append("\\r")
                '\t' -> out.append("\\t")
                '\b' -> out.append("\\b")
                '\u000C' -> out.append("\\f")
                else -> if (c < ' ') out.append("\\u%04x".format(c.code)) else out.append(c)
            }
        }
        out.append('"')
    }
}

/** `as? [String: Any]`, spelled for Kotlin. */
@Suppress("UNCHECKED_CAST")
fun Any?.asObject(): Map<String, Any?>? = this as? Map<String, Any?>

/** `as? String`. */
fun Any?.asString(): String? = this as? String

/**
 * `as? [String: String]`, with one deliberate difference: Swift's cast fails for the WHOLE
 * dictionary if any single value is not a string, while this keeps the string-valued entries.
 * Registry `dependencies` maps are all-string in practice, so the two agree on real documents.
 */
fun Any?.asStringMap(): Map<String, String> {
    val map = asObject() ?: return emptyMap()
    val out = LinkedHashMap<String, String>()
    for ((key, value) in map) if (value is String) out[key] = value
    return out
}
