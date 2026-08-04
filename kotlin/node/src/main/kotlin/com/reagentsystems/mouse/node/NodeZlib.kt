package com.reagentsystems.mouse.node

import java.io.ByteArrayOutputStream
import java.util.Base64
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger
import java.util.zip.CRC32
import java.util.zip.Deflater
import java.util.zip.Inflater

/**
 * `zlib` — gzip, deflate and their raw forms, one-shot and streaming.
 *
 * iOS drives zlib's own `z_stream` and gets the header handling free, because `windowBits`
 * selects it: 15 is the zlib wrapper, −15 raw, 15+16 gzip, and 15+32 auto-detects. `java.util.zip`
 * exposes exactly ONE of those choices — `Deflater(level, nowrap)` — so gzip's framing and the
 * auto-detect are written here.
 *
 * That is the whole of the difficulty, and it is worth naming precisely:
 *
 *  - **gzip's frame is ours to build.** A 10-byte header, raw deflate, then CRC32 and the
 *    uncompressed size, both little-endian. `GZIPOutputStream` would do it for the one-shot case
 *    and cannot do it incrementally, which the streaming path needs — so both paths use the same
 *    hand-built framing rather than two implementations that could disagree.
 *  - **auto-detect is ours too.** `gunzip`, `inflate` and `unzip` all arrive as 15+32 on iOS,
 *    meaning "gzip or zlib, whichever this is". Two bytes decide it: 0x1f 0x8b is gzip, anything
 *    else is taken as zlib.
 *
 * Everything crosses as base64 for the same reason the rest of the bridge does. A null answer
 * means the input was not valid for the mode, which is what the bootstrap turns into node's own
 * `Z_DATA_ERROR`.
 */
object NodeZlib {

    private const val DEFAULT_LEVEL = -1

    /** What a mode does, in the two decisions `java.util.zip` actually offers. */
    private enum class Wrap { ZLIB, RAW, GZIP, AUTO }

    private data class Mode(val deflating: Boolean, val wrap: Wrap)

    private val MODES = mapOf(
        "gzip" to Mode(true, Wrap.GZIP),
        "deflate" to Mode(true, Wrap.ZLIB),
        "deflateRaw" to Mode(true, Wrap.RAW),
        "inflateRaw" to Mode(false, Wrap.RAW),
        // iOS gives all three 15+32 — "gzip or zlib, whichever this turns out to be".
        "gunzip" to Mode(false, Wrap.AUTO),
        "inflate" to Mode(false, Wrap.AUTO),
        "unzip" to Mode(false, Wrap.AUTO),
    )

    private fun decode(base64: String): ByteArray? =
        if (base64.isEmpty()) ByteArray(0)
        else runCatching { Base64.getDecoder().decode(base64) }.getOrNull()

    private fun encode(bytes: ByteArray): String = Base64.getEncoder().encodeToString(bytes)

    // ------------------------------------------------------------------ one-shot ----

    /** `zlib.gzipSync` and friends: the whole buffer in, the whole buffer out. */
    fun transform(mode: String, base64: String, level: Int): String? {
        val spec = MODES[mode] ?: return null
        val input = decode(base64) ?: return null
        val out = runCatching {
            if (spec.deflating) deflateAll(input, spec.wrap, level) else inflateAll(input, spec.wrap)
        }.getOrNull() ?: return null
        return encode(out)
    }

    private fun deflateAll(input: ByteArray, wrap: Wrap, level: Int): ByteArray {
        val body = ByteArrayOutputStream()
        if (wrap == Wrap.GZIP) body.write(gzipHeader())
        val deflater = Deflater(if (level in 0..9) level else DEFAULT_LEVEL, wrap != Wrap.ZLIB)
        try {
            deflater.setInput(input)
            deflater.finish()
            val buffer = ByteArray(1 shl 15)
            while (!deflater.finished()) {
                val n = deflater.deflate(buffer)
                if (n <= 0) break
                body.write(buffer, 0, n)
            }
        } finally {
            deflater.end()
        }
        if (wrap == Wrap.GZIP) body.write(gzipTrailer(input))
        return body.toByteArray()
    }

    private fun inflateAll(input: ByteArray, wrap: Wrap): ByteArray {
        var body = input
        var raw = wrap == Wrap.RAW
        if (wrap == Wrap.AUTO) {
            if (isGzip(input)) {
                val start = gzipBodyStart(input) ?: throw IllegalArgumentException("bad gzip header")
                // The 8-byte trailer is not deflate data; Inflater tolerates trailing bytes, but
                // dropping them keeps "finished" meaning what it says.
                body = input.copyOfRange(start, maxOf(start, input.size - 8))
                raw = true
            } else {
                raw = false
            }
        }
        val inflater = Inflater(raw)
        try {
            inflater.setInput(body)
            val out = ByteArrayOutputStream()
            val buffer = ByteArray(1 shl 15)
            while (!inflater.finished()) {
                val n = inflater.inflate(buffer)
                if (n == 0) {
                    if (inflater.needsInput() || inflater.needsDictionary()) break
                } else {
                    out.write(buffer, 0, n)
                }
            }
            return out.toByteArray()
        } finally {
            inflater.end()
        }
    }

    // -------------------------------------------------------------------- gzip ----

    private fun isGzip(bytes: ByteArray): Boolean =
        bytes.size >= 2 && (bytes[0].toInt() and 0xff) == 0x1f && (bytes[1].toInt() and 0xff) == 0x8b

    /**
     * The fixed 10-byte header: magic, deflate, no flags, no mtime, no extra flags, unknown OS.
     * node writes an OS byte of 0x03 (Unix) and a zero mtime for a stream with no file behind it,
     * which is what this is.
     */
    private fun gzipHeader(): ByteArray = byteArrayOf(
        0x1f, 0x8b.toByte(), 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03,
    )

    /** CRC32 of the UNCOMPRESSED bytes, then their length, both little-endian. */
    private fun gzipTrailer(input: ByteArray): ByteArray {
        val crc = CRC32().apply { update(input) }.value
        val size = input.size.toLong()
        return byteArrayOf(
            (crc and 0xff).toByte(), ((crc shr 8) and 0xff).toByte(),
            ((crc shr 16) and 0xff).toByte(), ((crc shr 24) and 0xff).toByte(),
            (size and 0xff).toByte(), ((size shr 8) and 0xff).toByte(),
            ((size shr 16) and 0xff).toByte(), ((size shr 24) and 0xff).toByte(),
        )
    }

    /**
     * Where the deflate stream starts, past a gzip header with whatever optional fields it
     * carries. Null when the header is malformed or truncated.
     */
    private fun gzipBodyStart(bytes: ByteArray): Int? {
        if (bytes.size < 10 || !isGzip(bytes)) return null
        val flags = bytes[3].toInt() and 0xff
        var at = 10
        if (flags and 0x04 != 0) { // FEXTRA
            if (at + 2 > bytes.size) return null
            val length = (bytes[at].toInt() and 0xff) or ((bytes[at + 1].toInt() and 0xff) shl 8)
            at += 2 + length
        }
        if (flags and 0x08 != 0) { // FNAME, NUL-terminated
            while (at < bytes.size && bytes[at].toInt() != 0) at += 1
            at += 1
        }
        if (flags and 0x10 != 0) { // FCOMMENT, NUL-terminated
            while (at < bytes.size && bytes[at].toInt() != 0) at += 1
            at += 1
        }
        if (flags and 0x02 != 0) at += 2 // FHCRC
        return if (at <= bytes.size) at else null
    }

    // ----------------------------------------------------------------- streaming ----

    /**
     * A live coder. `http`'s gzip responses arrive in pieces and must be decoded in pieces, which
     * is the whole reason this exists beside the one-shot path.
     */
    private class Stream(val spec: Mode, val deflater: Deflater?, var inflater: Inflater?) {
        val crc = CRC32()
        var uncompressed = 0L
        var wroteHeader = false
        /** Undecided until the first bytes arrive: an AUTO stream does not know its own framing. */
        var resolved = false
        /** Bytes held back because a gzip header had not fully arrived yet. */
        var pending = ByteArray(0)
    }

    private val streams = ConcurrentHashMap<Int, Stream>()
    private val handles = AtomicInteger(1)

    /** Open a coder. 0 means the mode is unknown — the value the bootstrap treats as failure. */
    fun open(mode: String): Int {
        val spec = MODES[mode] ?: return 0
        val handle = handles.getAndIncrement()
        val stream = if (spec.deflating) {
            Stream(spec, Deflater(DEFAULT_LEVEL, spec.wrap != Wrap.ZLIB), null)
        } else {
            // An AUTO stream cannot choose `nowrap` until it has seen the first two bytes.
            Stream(spec, null, if (spec.wrap == Wrap.AUTO) null else Inflater(spec.wrap == Wrap.RAW))
        }
        streams[handle] = stream
        return handle
    }

    /** Push a chunk; `finish` flushes and completes the frame. Null on a stream that is not open. */
    fun push(handle: Int, base64: String, finish: Boolean): String? {
        val stream = streams[handle] ?: return null
        val input = decode(base64) ?: return null
        return runCatching {
            encode(if (stream.spec.deflating) pushDeflate(stream, input, finish) else pushInflate(stream, input, finish))
        }.getOrNull()
    }

    private fun pushDeflate(stream: Stream, input: ByteArray, finish: Boolean): ByteArray {
        val deflater = stream.deflater ?: return ByteArray(0)
        val out = ByteArrayOutputStream()
        if (stream.spec.wrap == Wrap.GZIP && !stream.wroteHeader) {
            out.write(gzipHeader())
            stream.wroteHeader = true
        }
        if (input.isNotEmpty()) {
            stream.crc.update(input)
            stream.uncompressed += input.size
            deflater.setInput(input)
        }
        if (finish) deflater.finish()
        val buffer = ByteArray(1 shl 15)
        while (true) {
            // SYNC_FLUSH while the stream is live: without it a chunk can sit in the coder's own
            // buffer, and a caller that pushed data and got nothing back reads that as a stall.
            val n = if (finish) deflater.deflate(buffer) else deflater.deflate(buffer, 0, buffer.size, Deflater.SYNC_FLUSH)
            if (n <= 0) break
            out.write(buffer, 0, n)
            if (!finish && n < buffer.size) break
        }
        if (finish) {
            if (stream.spec.wrap == Wrap.GZIP) {
                val crc = stream.crc.value
                val size = stream.uncompressed
                out.write(
                    byteArrayOf(
                        (crc and 0xff).toByte(), ((crc shr 8) and 0xff).toByte(),
                        ((crc shr 16) and 0xff).toByte(), ((crc shr 24) and 0xff).toByte(),
                        (size and 0xff).toByte(), ((size shr 8) and 0xff).toByte(),
                        ((size shr 16) and 0xff).toByte(), ((size shr 24) and 0xff).toByte(),
                    ),
                )
            }
        }
        return out.toByteArray()
    }

    private fun pushInflate(stream: Stream, input: ByteArray, finish: Boolean): ByteArray {
        var data = if (stream.pending.isEmpty()) input else stream.pending + input
        stream.pending = ByteArray(0)
        if (stream.spec.wrap == Wrap.AUTO && !stream.resolved) {
            if (data.size < 2) {
                // Not enough to tell yet. Hold it: guessing here would pick the wrong framing for
                // the whole stream on the strength of one byte.
                stream.pending = data
                return ByteArray(0)
            }
            if (isGzip(data)) {
                val start = gzipBodyStart(data)
                if (start == null) {
                    stream.pending = data
                    return ByteArray(0)
                }
                data = data.copyOfRange(start, data.size)
                stream.inflater = Inflater(true)
            } else {
                stream.inflater = Inflater(false)
            }
            stream.resolved = true
        }
        val inflater = stream.inflater ?: return ByteArray(0)
        val out = ByteArrayOutputStream()
        if (data.isNotEmpty()) inflater.setInput(data)
        val buffer = ByteArray(1 shl 15)
        while (!inflater.finished()) {
            val n = inflater.inflate(buffer)
            if (n == 0) {
                if (inflater.needsInput() || inflater.needsDictionary()) break
            } else {
                out.write(buffer, 0, n)
            }
        }
        return out.toByteArray()
    }

    /** Release a coder. Idempotent: a stream may be closed by `finish` and again by the caller. */
    fun close(handle: Int) {
        val stream = streams.remove(handle) ?: return
        stream.deflater?.end()
        stream.inflater?.end()
    }
}
