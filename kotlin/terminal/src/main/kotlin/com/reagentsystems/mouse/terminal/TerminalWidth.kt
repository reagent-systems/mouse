package com.reagentsystems.mouse.terminal

/**
 * How many COLUMNS a character occupies on the grid (system.md phase T).
 *
 * A terminal cell is not a character — it is a column. CJK, Kana, Hangul, fullwidth forms and
 * most emoji occupy TWO of them, and `TerminalScreen.put` used to advance exactly one per
 * character. The visible result is that every TUI drawing a box, a table or an aligned column
 * with non-Latin text comes out crooked, with the error growing along the line: `less` on a
 * Japanese file, a progress bar next to an emoji, ink's own borders.
 *
 * The wide ranges are East Asian Width W and F from UAX #11, generated from Unicode 16.0.0
 * rather than hand-written — a hand-kept table of 103 ranges rots, and the generator is
 * recorded so it can be regenerated. Zero-width characters do NOT need a table: the platform
 * already exposes the general category (`Character.getType`), and a printed unit here is a
 * grapheme cluster, so a combining mark has usually merged into its base before it ever
 * reaches here.
 *
 * Kotlin note: Swift's `Character` is a grapheme cluster, so the iOS signature takes one.
 * Kotlin's `Char` is a UTF-16 code unit, which cannot hold an emoji at all — so a cluster is a
 * `String` here and the arithmetic is done in code points. Semantics are unchanged.
 */
object TerminalWidth {

    /** East Asian Wide and Fullwidth, as flat (lowerBound, upperBound) code-point pairs. */
    private val wideRanges = intArrayOf(
        0x1100, 0x115F,
        0x231A, 0x231B,
        0x2329, 0x232A,
        0x23E9, 0x23EC,
        0x23F0, 0x23F0,
        0x23F3, 0x23F3,
        0x25FD, 0x25FE,
        0x2614, 0x2615,
        0x2630, 0x2637,
        0x2648, 0x2653,
        0x267F, 0x267F,
        0x268A, 0x268F,
        0x2693, 0x2693,
        0x26A1, 0x26A1,
        0x26AA, 0x26AB,
        0x26BD, 0x26BE,
        0x26C4, 0x26C5,
        0x26CE, 0x26CE,
        0x26D4, 0x26D4,
        0x26EA, 0x26EA,
        0x26F2, 0x26F5,
        0x26FA, 0x26FA,
        0x26FD, 0x26FD,
        0x2705, 0x2705,
        0x270A, 0x270B,
        0x2728, 0x2728,
        0x274C, 0x274E,
        0x2753, 0x2757,
        0x2795, 0x2797,
        0x27B0, 0x27B0,
        0x27BF, 0x27BF,
        0x2B1B, 0x2B1C,
        0x2B50, 0x2B50,
        0x2B55, 0x2B55,
        0x2E80, 0x2EF3,
        0x2F00, 0x2FD5,
        0x2FF0, 0x303E,
        0x3041, 0x3096,
        0x3099, 0x30FF,
        0x3105, 0x31E5,
        0x31EF, 0x3247,
        0x3250, 0xA48C,
        0xA490, 0xA4C6,
        0xA960, 0xA97C,
        0xAC00, 0xD7A3,
        0xF900, 0xFAFF,
        0xFE10, 0xFE19,
        0xFE30, 0xFE6B,
        0xFF01, 0xFF60,
        0xFFE0, 0xFFE6,
        0x16FE0, 0x16FE4,
        0x16FF0, 0x16FF1,
        0x17000, 0x187F7,
        0x18800, 0x18CD5,
        0x18CFF, 0x18D08,
        0x1AFF0, 0x1B122,
        0x1B132, 0x1B132,
        0x1B150, 0x1B152,
        0x1B155, 0x1B155,
        0x1B164, 0x1B167,
        0x1B170, 0x1B2FB,
        0x1D300, 0x1D356,
        0x1D360, 0x1D376,
        0x1F004, 0x1F004,
        0x1F0CF, 0x1F0CF,
        0x1F18E, 0x1F18E,
        0x1F191, 0x1F19A,
        0x1F200, 0x1F202,
        0x1F210, 0x1F23B,
        0x1F240, 0x1F248,
        0x1F250, 0x1F251,
        0x1F260, 0x1F265,
        0x1F300, 0x1F320,
        0x1F32D, 0x1F393,
        0x1F3A0, 0x1F3CA,
        0x1F3CF, 0x1F3D3,
        0x1F3E0, 0x1F3F0,
        0x1F3F4, 0x1F3F4,
        0x1F3F8, 0x1F4FC,
        0x1F4FF, 0x1F53D,
        0x1F54B, 0x1F567,
        0x1F57A, 0x1F57A,
        0x1F595, 0x1F596,
        0x1F5A4, 0x1F5A4,
        0x1F5FB, 0x1F64F,
        0x1F680, 0x1F6C5,
        0x1F6CC, 0x1F6CC,
        0x1F6D0, 0x1F6D2,
        0x1F6D5, 0x1F6D7,
        0x1F6DC, 0x1F6DF,
        0x1F6EB, 0x1F6EC,
        0x1F6F4, 0x1F6FC,
        0x1F7E0, 0x1F7EB,
        0x1F7F0, 0x1F7F0,
        0x1F90C, 0x1F9FF,
        0x1FA70, 0x1FA7C,
        0x1FA80, 0x1FA89,
        0x1FA8F, 0x1FAC6,
        0x1FACE, 0x1FADC,
        0x1FADF, 0x1FAE9,
        0x1FAF0, 0x1FAF8,
        0x20000, 0x2FFFD,
        0x30000, 0x3FFFD,
    )

    /** Binary search — this runs for every character written to the screen. */
    private fun isWide(codePoint: Int): Boolean {
        var low = 0
        var high = wideRanges.size / 2 - 1
        while (low <= high) {
            val middle = (low + high) / 2
            val lower = wideRanges[middle * 2]
            val upper = wideRanges[middle * 2 + 1]
            if (codePoint < lower) high = middle - 1
            else if (codePoint > upper) low = middle + 1
            else return true
        }
        return false
    }

    /**
     * 0 for a mark or format character, 2 for East Asian wide, 1 otherwise.
     *
     * The FIRST code point decides: a grapheme cluster like an emoji with a variation selector
     * or a ZWJ sequence takes its width from the base character, which is what terminals do
     * (and why a family emoji is two columns wide, not eight).
     */
    fun columns(character: String): Int {
        if (character.isEmpty()) return 0
        val first = character.codePointAt(0)
        // A control character occupies nothing; the parser handles it before this point, but a
        // stray one must not silently consume a column.
        if (first < 0x20 || first == 0x7F) return 0
        when (Character.getType(first)) {
            Character.NON_SPACING_MARK.toInt(),
            Character.ENCLOSING_MARK.toInt(),
            Character.FORMAT.toInt() ->
                // U+00AD SOFT HYPHEN is a format character that terminals still show.
                if (first != 0x00AD) return 0
        }
        // An emoji presentation selector promotes an otherwise narrow base to two columns.
        var index = 0
        while (index < character.length) {
            val codePoint = character.codePointAt(index)
            if (codePoint == 0xFE0F) return 2
            index += Character.charCount(codePoint)
        }
        return if (isWide(first)) 2 else 1
    }
}
