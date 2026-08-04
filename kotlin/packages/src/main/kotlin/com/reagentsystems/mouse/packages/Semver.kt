package com.reagentsystems.mouse.packages

/**
 * Semver, ported assertion-for-assertion from `PackageManager.Semver` in
 * `swift/Mouse/PackageManager.swift`. Top-level here because Kotlin has real packages; on iOS
 * these are nested inside the `PackageManager` namespace enum.
 *
 * The answers must match the Swift side EXACTLY, prerelease ordering included: the corpus that
 * gates this is checked against a real package manager, so "close enough" resolves a different
 * tree and the two apps stop installing the same thing.
 */
class Semver(
    val major: Int,
    val minor: Int,
    val patch: Int,
    /** Dot-separated prerelease identifiers; empty means a release version. */
    val prerelease: List<String> = emptyList(),
) : Comparable<Semver> {

    override fun toString(): String =
        "$major.$minor.$patch" + if (prerelease.isEmpty()) "" else "-" + prerelease.joinToString(".")

    override fun compareTo(other: Semver): Int {
        if (major != other.major) return major.compareTo(other.major)
        if (minor != other.minor) return minor.compareTo(other.minor)
        if (patch != other.patch) return patch.compareTo(other.patch)
        // A release outranks any of its prereleases.
        if (prerelease.isEmpty() != other.prerelease.isEmpty()) return if (prerelease.isEmpty()) 1 else -1
        for (i in 0 until minOf(prerelease.size, other.prerelease.size)) {
            val l = prerelease[i]
            val r = other.prerelease[i]
            if (l == r) continue
            val li = l.toIntOrNull()
            val ri = r.toIntOrNull()
            return when {
                li != null && ri != null -> li.compareTo(ri)
                li != null -> -1 // numeric < alphanumeric
                ri != null -> 1
                else -> l.compareTo(r)
            }
        }
        return prerelease.size.compareTo(other.prerelease.size)
    }

    override fun equals(other: Any?): Boolean =
        other is Semver && major == other.major && minor == other.minor && patch == other.patch &&
            prerelease == other.prerelease

    override fun hashCode(): Int =
        ((major * 31 + minor) * 31 + patch) * 31 + prerelease.hashCode()

    companion object {
        /** null when the text is not a full `major.minor.patch`. */
        fun parse(raw: String): Semver? {
            var text = raw.trim()
            if (text.startsWith("v")) text = text.substring(1)
            // Build metadata (+…) never affects precedence.
            val plus = text.indexOf('+')
            if (plus >= 0) text = text.substring(0, plus)
            var pre = emptyList<String>()
            val dash = text.indexOf('-')
            if (dash >= 0) {
                pre = text.substring(dash + 1).split(".").filter { it.isNotEmpty() }
                text = text.substring(0, dash)
            }
            val parts = text.split(".")
            if (parts.size != 3) return null
            val major = parts[0].toIntOrNull() ?: return null
            val minor = parts[1].toIntOrNull() ?: return null
            val patch = parts[2].toIntOrNull() ?: return null
            return Semver(major, minor, patch, pre)
        }
    }
}

/** One comparator: an operator against a version. (`PackageManager.Comparator` on iOS; renamed here so it cannot be confused with kotlin.Comparator, which is imported by default.) */
internal class SemverComparator(val op: Op, val version: Semver) {
    enum class Op { LT, LE, GT, GE, EQ }

    fun satisfiedBy(candidate: Semver): Boolean = when (op) {
        Op.LT -> candidate < version
        Op.LE -> candidate <= version
        Op.GT -> candidate > version
        Op.GE -> candidate >= version
        Op.EQ -> candidate == version
    }
}

/** A range: OR of comparator sets (`^1.2 || >=3.0.0 <4`). Each set ANDs its comparators. */
class SemverRange private constructor(
    private val sets: List<List<SemverComparator>>,
    /**
     * Triples that appeared with a prerelease in the source range — the only versions whose
     * prereleases the range may match (the semver prerelease rule).
     */
    private val prereleaseAnchors: List<List<Int>>,
) {

    fun satisfiedBy(candidate: Semver): Boolean {
        if (candidate.prerelease.isNotEmpty()) {
            val triple = listOf(candidate.major, candidate.minor, candidate.patch)
            if (!prereleaseAnchors.contains(triple)) return false
        }
        return sets.any { set -> set.all { it.satisfiedBy(candidate) } }
    }

    companion object {
        /** null when any alternative in the range fails to parse. */
        fun parse(text: String): SemverRange? {
            val sets = ArrayList<List<SemverComparator>>()
            val anchors = ArrayList<List<Int>>()
            for (alternative in text.split("||")) {
                val set = parseSet(alternative, anchors) ?: return null
                sets.add(set)
            }
            if (sets.isEmpty()) return null
            return SemverRange(sets, anchors)
        }

        private fun parseSet(raw: String, anchors: MutableList<List<Int>>): List<SemverComparator>? {
            val comparators = ArrayList<SemverComparator>()
            // Hyphen ranges: "1.2.3 - 2.0.0" (the spaces are the syntax).
            val text = raw.trim()
            val hyphen = text.indexOf(" - ")
            if (hyphen >= 0) {
                val low = text.substring(0, hyphen)
                val high = text.substring(hyphen + 3)
                val lower = fill(low) ?: return null
                comparators.add(SemverComparator(SemverComparator.Op.GE, lower))
                val exact = Semver.parse(high)
                if (exact != null && countParts(high) == 3) {
                    comparators.add(SemverComparator(SemverComparator.Op.LE, exact))
                } else {
                    val upper = fill(high) ?: return comparators
                    comparators.add(SemverComparator(SemverComparator.Op.LT, bumpPartial(high, upper)))
                }
                return comparators
            }
            var tokens = text.split(" ").filter { it.isNotEmpty() }
            // The spec allows whitespace between an operator and its version (">= 2.1.2 < 3.0.0",
            // safer-buffer's published range): rejoin bare-operator tokens with the version that
            // follows.
            val joined = ArrayList<String>()
            var index = 0
            while (index < tokens.size) {
                val token = tokens[index]
                if (token in setOf("<", "<=", ">", ">=", "=", "~", "^") && index + 1 < tokens.size) {
                    joined.add(token + tokens[index + 1])
                    index += 2
                } else {
                    joined.add(token)
                    index += 1
                }
            }
            tokens = joined
            if (tokens.isEmpty()) return listOf(SemverComparator(SemverComparator.Op.GE, Semver(0, 0, 0)))
            for (token in tokens) {
                val parsed = parseComparator(token, anchors) ?: return null
                comparators.addAll(parsed)
            }
            return comparators
        }

        private fun countParts(raw: String): Int {
            var text = raw
            val dash = text.indexOf('-')
            if (dash >= 0) text = text.substring(0, dash)
            return text.split(".").filter { it.isNotEmpty() }.size
        }

        /** "1.2" → 1.2.0 (missing parts become 0; `x`/`*` too). */
        private fun fill(raw: String): Semver? {
            var text = raw.trim()
            if (text.startsWith("v")) text = text.substring(1)
            var pre = emptyList<String>()
            val dash = text.indexOf('-')
            if (dash >= 0) {
                pre = text.substring(dash + 1).split(".").filter { it.isNotEmpty() }
                text = text.substring(0, dash)
            }
            val parts = ArrayList<Int>()
            for (piece in text.split(".")) {
                if (piece == "x" || piece == "X" || piece == "*" || piece.isEmpty()) break
                parts.add(piece.toIntOrNull() ?: return null)
            }
            while (parts.size < 3) parts.add(0)
            return Semver(parts[0], parts[1], parts[2], pre)
        }

        /** The exclusive upper bound implied by a partial: "1.2" → 1.3.0, "1" → 2.0.0. */
        private fun bumpPartial(text: String, filled: Semver): Semver = when (countExplicit(text)) {
            0 -> Semver(Int.MAX_VALUE, 0, 0)
            1 -> Semver(filled.major + 1, 0, 0)
            2 -> Semver(filled.major, filled.minor + 1, 0)
            else -> Semver(filled.major, filled.minor, filled.patch + 1)
        }

        private fun countExplicit(raw: String): Int {
            var text = raw.trim()
            if (text.startsWith("v")) text = text.substring(1)
            val dash = text.indexOf('-')
            if (dash >= 0) text = text.substring(0, dash)
            var count = 0
            for (piece in text.split(".")) {
                if (piece == "x" || piece == "X" || piece == "*" || piece.isEmpty()) break
                if (piece.toIntOrNull() == null) break
                count += 1
            }
            return count
        }

        private fun parseComparator(token: String, anchors: MutableList<List<Int>>): List<SemverComparator>? {
            fun anchor(version: Semver) {
                if (version.prerelease.isNotEmpty()) {
                    anchors.add(listOf(version.major, version.minor, version.patch))
                }
            }
            if (token == "*" || token == "x" || token == "X" || token == "latest") {
                return listOf(SemverComparator(SemverComparator.Op.GE, Semver(0, 0, 0)))
            }
            if (token.startsWith("^")) {
                val body = token.substring(1)
                val version = fill(body) ?: return null
                anchor(version)
                val explicit = countExplicit(body)
                val upper = when {
                    version.major > 0 || explicit <= 1 -> Semver(version.major + 1, 0, 0)
                    version.minor > 0 || explicit == 2 -> Semver(0, version.minor + 1, 0)
                    else -> Semver(0, version.minor, version.patch + 1)
                }
                return listOf(SemverComparator(SemverComparator.Op.GE, version), SemverComparator(SemverComparator.Op.LT, upper))
            }
            if (token.startsWith("~")) {
                val body = token.substring(1)
                val version = fill(body) ?: return null
                anchor(version)
                val upper = if (countExplicit(body) <= 1) {
                    Semver(version.major + 1, 0, 0)
                } else {
                    Semver(version.major, version.minor + 1, 0)
                }
                return listOf(SemverComparator(SemverComparator.Op.GE, version), SemverComparator(SemverComparator.Op.LT, upper))
            }
            // ">=" before ">", "<=" before "<": the order of this list is the parse.
            for ((prefix, op) in listOf(
                ">=" to SemverComparator.Op.GE,
                "<=" to SemverComparator.Op.LE,
                ">" to SemverComparator.Op.GT,
                "<" to SemverComparator.Op.LT,
                "=" to SemverComparator.Op.EQ,
            )) {
                if (token.startsWith(prefix)) {
                    val body = token.substring(prefix.length)
                    val version = fill(body) ?: return null
                    anchor(version)
                    // ">1.2" on a partial means ">=1.3.0"; "<1.2" means "<1.2.0" (the fill).
                    if (op == SemverComparator.Op.GT && countExplicit(body) < 3) {
                        return listOf(SemverComparator(SemverComparator.Op.GE, bumpPartial(body, version)))
                    }
                    if (op == SemverComparator.Op.EQ && countExplicit(body) < 3) {
                        return listOf(
                            SemverComparator(SemverComparator.Op.GE, version),
                            SemverComparator(SemverComparator.Op.LT, bumpPartial(body, version)),
                        )
                    }
                    return listOf(SemverComparator(op, version))
                }
            }
            // Bare version: exact when full, an x-range when partial ("1.2" == ">=1.2.0 <1.3.0").
            if (countExplicit(token) == 3) {
                val version = Semver.parse(token)
                if (version != null) {
                    anchor(version)
                    return listOf(SemverComparator(SemverComparator.Op.EQ, version))
                }
            }
            val version = fill(token) ?: return null
            return listOf(
                SemverComparator(SemverComparator.Op.GE, version),
                SemverComparator(SemverComparator.Op.LT, bumpPartial(token, version)),
            )
        }
    }
}
