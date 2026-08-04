package com.reagentsystems.mouse.packages

import java.io.ByteArrayOutputStream
import java.io.File
import java.io.InputStream
import java.io.OutputStream
import java.nio.file.Files
import java.nio.file.Paths
import java.util.zip.GZIPInputStream
import java.util.zip.Inflater

/**
 * Native .tar.gz extraction: gzip via the platform, tar parsed by hand (ustar + GNU longname +
 * pax path records — enough for GitHub tarballs and npm registry tarballs).
 *
 * Ported from `TarGz` in `swift/Mouse/PackageManager.swift`, and it lives beside the package
 * manager for the same reason it does there: the workspace clone and the npm installer are the
 * two callers, and only this module is reachable from a headless harness.
 *
 * One deliberate divergence from the Swift file, and it is a subtraction: iOS parses the gzip
 * HEADER by hand because the Compression framework's ZLIB mode is raw DEFLATE and cannot see
 * gzip framing. The JDK ships `GZIPInputStream`, which does the framing (and concatenated
 * members) correctly, so that hand-rolled header walk has no reason to exist here.
 */
object TarGz {
    class ExtractError(message: String) : Exception(message)

    /**
     * Unpack, STREAMING the gzip rather than expanding it whole.
     *
     * The obvious shape — `gunzip(tgz)` into one array, then walk it — is what this used to be,
     * and it dies on a phone. Ruby's 25 MB release tarball expands past 130 MB, a
     * `ByteArrayOutputStream` needs momentarily twice that while it doubles, and Android's default
     * heap growth limit is around 200 MB: `pkg install ruby` took the whole app down with
     * `OutOfMemoryError: Failed to allocate a 134217744 byte allocation`. The desktop JVM harness
     * never saw it, because a desktop heap absorbs it without noticing.
     *
     * Reading entry by entry means peak memory is one file plus a 64 KB buffer, whatever the
     * archive's size. Every caller benefits: the workspace clone and the npm installer were one
     * large repository away from the same crash.
     */
    fun extract(tgz: ByteArray, into: File, stripComponents: Int = 0) {
        if (tgz.size < 3 || tgz[0].toInt() and 0xFF != 0x1f || tgz[1].toInt() and 0xFF != 0x8b) {
            throw ExtractError("not a gzip archive")
        }
        try {
            GZIPInputStream(tgz.inputStream(), 1 shl 16).use { stream ->
                extractTar(stream, into, stripComponents)
            }
        } catch (e: ExtractError) {
            throw e
        } catch (e: Exception) {
            throw ExtractError("corrupt archive: ${e.message}")
        }
    }

    private fun extractTar(stream: InputStream, into: File, stripComponents: Int) {
        val header = ByteArray(512)
        var pendingLongName: String? = null
        var pendingPaxPath: String? = null

        while (readFully(stream, header, 512)) {
            if (header.all { it.toInt() == 0 }) continue // end-of-archive padding

            val size = numeric(header, 124, 12)
            val typeFlag = header[156].toInt() and 0xFF
            var name = field(header, 0, 100)
            val prefix = field(header, 345, 155)
            if (prefix.isNotEmpty()) name = "$prefix/$name"
            pendingLongName?.let { name = it; pendingLongName = null }
            pendingPaxPath?.let { name = it; pendingPaxPath = null }
            val padding = (512 - size % 512) % 512

            when (typeFlag) {
                'L'.code -> { // GNU long name: content is the next entry's path
                    pendingLongName = String(readMetadata(stream, size), Charsets.UTF_8).trim(' ', Char(0))
                    skipFully(stream, padding)
                    continue
                }
                'x'.code -> { // pax extended header: may override the next entry's path
                    pendingPaxPath = paxValue(readMetadata(stream, size), "path")
                    skipFully(stream, padding)
                    continue
                }
                'g'.code -> { // pax global header: ignore
                    skipFully(stream, size + padding)
                    continue
                }
            }

            val components = name.split("/").filter { it.isNotEmpty() }.toMutableList()
            val usable = components.size > stripComponents
            if (usable) repeat(stripComponents) { components.removeAt(0) }
            // Never let an archive write outside the destination.
            val target = if (usable && components.isNotEmpty() && !components.contains("..")) {
                components.fold(into) { dir, part -> File(dir, part) }
            } else {
                null
            }

            when (typeFlag) {
                '5'.code -> {
                    target?.mkdirs()
                    skipFully(stream, size + padding)
                }
                0, '0'.code, '7'.code -> {
                    if (target == null) {
                        skipFully(stream, size + padding)
                    } else {
                        target.parentFile?.mkdirs()
                        // Straight from the gzip stream to the file: this is the whole point.
                        target.outputStream().use { copyExactly(stream, it, size) }
                        skipFully(stream, padding)
                    }
                }
                '2'.code -> {
                    if (target != null) {
                        val linkTarget = field(header, 157, 100)
                        target.parentFile?.mkdirs()
                        target.delete()
                        runCatching { Files.createSymbolicLink(target.toPath(), Paths.get(linkTarget)) }
                    }
                    skipFully(stream, size + padding)
                }
                // hardlinks, fifos, devices: skip
                else -> skipFully(stream, size + padding)
            }
        }
    }

    /**
     * A metadata entry (a GNU long name, a pax record block) is read into memory because its whole
     * text is needed at once — but it is a PATH, not a payload, so a header claiming megabytes is
     * a malformed or hostile archive rather than a large one.
     */
    private fun readMetadata(stream: InputStream, size: Int): ByteArray {
        if (size < 0 || size > 1 shl 20) throw ExtractError("a tar metadata header claims $size bytes")
        val bytes = ByteArray(size)
        if (size > 0 && !readFully(stream, bytes, size)) throw ExtractError("archive ends inside a header")
        return bytes
    }

    /** Fill `count` bytes or report the stream ended; a partial read is a truncated archive. */
    private fun readFully(stream: InputStream, into: ByteArray, count: Int): Boolean {
        var read = 0
        while (read < count) {
            val got = stream.read(into, read, count - read)
            if (got < 0) return false
            read += got
        }
        return true
    }

    private fun copyExactly(stream: InputStream, out: OutputStream, count: Int) {
        val buffer = ByteArray(1 shl 16)
        var remaining = count
        while (remaining > 0) {
            val got = stream.read(buffer, 0, minOf(buffer.size, remaining))
            if (got < 0) throw ExtractError("archive ends inside an entry")
            out.write(buffer, 0, got)
            remaining -= got
        }
    }

    /**
     * `InputStream.skip` on an inflating stream may return short without being at EOF, so a single
     * call can silently leave the reader mid-entry and desynchronise every header after it.
     */
    private fun skipFully(stream: InputStream, count: Int) {
        var remaining = count.toLong()
        while (remaining > 0) {
            val skipped = stream.skip(remaining)
            if (skipped > 0) {
                remaining -= skipped
                continue
            }
            if (stream.read() < 0) return
            remaining -= 1
        }
    }

    /** NUL-terminated fixed-width text field. */
    private fun field(header: ByteArray, start: Int, len: Int): String {
        val bytes = ArrayList<Byte>(len)
        for (i in start until start + len) {
            val c = header[i]
            if (c.toInt() == 0) break
            bytes.add(c)
        }
        return String(bytes.toByteArray(), Charsets.UTF_8).trim()
    }

    /** Octal size field, with GNU base-256 fallback for huge entries. */
    private fun numeric(header: ByteArray, start: Int, len: Int): Int {
        if (header[start].toInt() and 0x80 != 0) {
            var value = 0
            for (i in 1 until len) value = value shl 8 or (header[start + i].toInt() and 0xFF)
            return value
        }
        var value = 0
        for (i in start until start + len) {
            val c = header[i].toInt() and 0xFF
            if (c in 0x30..0x37) value = value * 8 + (c - 0x30)
            else if (value > 0) break
        }
        return value
    }

    /** Parse a pax record stream ("<len> <key>=<value>\n"...) for one key. */
    private fun paxValue(content: ByteArray, key: String): String? {
        val text = String(content, Charsets.UTF_8)
        var rest = text
        while (true) {
            val space = rest.indexOf(' ')
            if (space < 0) return null
            val length = rest.substring(0, space).toIntOrNull() ?: return null
            if (length <= 0 || length > rest.length) return null
            val record = rest.substring(space + 1, length).dropLast(1) // trailing \n
            if (record.startsWith("$key=")) return record.substring(key.length + 1)
            rest = rest.substring(length)
        }
    }

    fun gunzip(data: ByteArray): ByteArray {
        if (data.size < 3 || data[0].toInt() and 0xFF != 0x1f || data[1].toInt() and 0xFF != 0x8b) {
            throw ExtractError("not a gzip archive")
        }
        return try {
            GZIPInputStream(data.inputStream()).use { it.readBytes() }
        } catch (e: Exception) {
            throw ExtractError("corrupt archive: ${e.message}")
        }
    }

    /**
     * Raw DEFLATE, the same stream a zip entry holds — this is what a `ZipArchive` needs to
     * unpack a downloaded language runtime, which is why it is exposed separately from `gunzip`.
     */
    fun inflateRaw(input: ByteArray): ByteArray {
        val inflater = Inflater(true)
        inflater.setInput(input)
        val out = ByteArrayOutputStream(input.size * 4)
        val chunk = ByteArray(1 shl 16)
        try {
            while (!inflater.finished()) {
                val produced = inflater.inflate(chunk)
                if (produced == 0) {
                    if (inflater.needsInput() || inflater.needsDictionary()) break
                } else {
                    out.write(chunk, 0, produced)
                }
            }
        } catch (e: Exception) {
            throw ExtractError("corrupt archive: ${e.message}")
        } finally {
            inflater.end()
        }
        return out.toByteArray()
    }
}
