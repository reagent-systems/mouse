package com.reagentsystems.mouse.node

import java.io.File

/**
 * `process.cpuUsage()` — user and system CPU time for this process, in MICROSECONDS.
 *
 * The iOS block reads `getrusage(RUSAGE_SELF)`. There is no `getrusage` from the JDK and no JNI
 * here (invariant #4 forbids the artifact, and a `.so` is not something this project ships), but
 * Linux — which Android is — publishes the same two numbers in `/proc/self/stat`, fields 14 and
 * 15, in clock ticks. That is where `getrusage` gets them from on Linux in the first place.
 *
 * It matters that this is real. The iOS comment on the same block records what it replaced:
 * "`process.cpuUsage()` returned hardcoded zeros, which is the shape of stub this project refuses:
 * it looks like a working API and silently reports nothing." So the parsing is a pure function
 * with its own corpus, and [read] answers null — not zeros — where there is no `/proc`, which is
 * every machine the JVM gate runs on and no machine the app runs on. The bridge then reports the
 * same `{user: 0, system: 0}` the Swift block reports when `getrusage` fails, so a caller sees one
 * shape of failure rather than two.
 */
object NodeCpu {

    /**
     * Clock ticks per second. POSIX `sysconf(_SC_CLK_TCK)`, which the JDK does not expose; it is
     * 100 on every Linux ABI Android has ever shipped, and the kernel's own `/proc` documentation
     * treats `USER_HZ = 100` as the fixed unit those fields are reported in.
     */
    const val CLOCK_TICKS_PER_SECOND: Long = 100

    /** User and system time, in microseconds — node's unit for `process.cpuUsage()`. */
    data class Usage(val userMicros: Double, val systemMicros: Double)

    /**
     * Parse one `/proc/<pid>/stat` line.
     *
     * The awkward part is field 2, `comm`, which is the executable name IN PARENTHESES and may
     * itself contain spaces and parentheses — Android's process names are package names, and a
     * WebView renderer is `…:sandboxed_process0`. Splitting the whole line on spaces therefore
     * mis-numbers every field after it, which is exactly the bug that makes a reader like this
     * report plausible nonsense. So the scan starts after the LAST `)`, which is what the kernel
     * itself documents as the way to read this file.
     */
    fun parse(line: String, ticksPerSecond: Long = CLOCK_TICKS_PER_SECOND): Usage? {
        val close = line.lastIndexOf(')')
        if (close < 0 || ticksPerSecond <= 0) return null
        // Field 3 (`state`) is the first one after `comm`, so index 0 here is field 3 and the
        // pair wanted — utime (14) and stime (15) — is at 11 and 12.
        val fields = line.substring(close + 1).trim().split(Regex("\\s+"))
        if (fields.size < 13) return null
        val user = fields[11].toLongOrNull() ?: return null
        val system = fields[12].toLongOrNull() ?: return null
        if (user < 0 || system < 0) return null
        val perTick = 1_000_000.0 / ticksPerSecond
        return Usage(user * perTick, system * perTick)
    }

    /** This process's CPU time, or null where there is no `/proc` (every non-Linux host). */
    fun read(): Usage? {
        val stat = File("/proc/self/stat")
        if (!stat.canRead()) return null
        return try {
            parse(stat.readText())
        } catch (_: Exception) {
            null
        }
    }
}
