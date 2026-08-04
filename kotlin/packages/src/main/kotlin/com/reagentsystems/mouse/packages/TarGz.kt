package com.reagentsystems.mouse.packages

import java.io.ByteArrayOutputStream
import java.io.File
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

    fun extract(tgz: ByteArray, into: File, stripComponents: Int = 0) {
        val tar = gunzip(tgz)
        var offset = 0
        var pendingLongName: String? = null
        var pendingPaxPath: String? = null

        while (offset + 512 <= tar.size) {
            val header = tar.copyOfRange(offset, offset + 512)
            offset += 512
            if (header.all { it.toInt() == 0 }) continue // end-of-archive padding

            val size = numeric(header, 124, 12)
            val typeFlag = header[156].toInt() and 0xFF
            var name = field(header, 0, 100)
            val prefix = field(header, 345, 155)
            if (prefix.isNotEmpty()) name = "$prefix/$name"
            pendingLongName?.let { name = it; pendingLongName = null }
            pendingPaxPath?.let { name = it; pendingPaxPath = null }

            val contentEnd = minOf(offset + size, tar.size)
            val content = if (size > 0 && offset < contentEnd) tar.copyOfRange(offset, contentEnd) else ByteArray(0)
            offset += (size + 511) / 512 * 512

            when (typeFlag) {
                'L'.code -> { // GNU long name: content is the next entry's path
                    pendingLongName = String(content, Charsets.UTF_8).trim(' ', Char(0))
                    continue
                }
                'x'.code -> { // pax extended header: may override the next entry's path
                    pendingPaxPath = paxValue(content, "path")
                    continue
                }
                'g'.code -> continue // pax global header: ignore
            }

            val components = name.split("/").filter { it.isNotEmpty() }.toMutableList()
            if (components.size <= stripComponents) continue
            repeat(stripComponents) { components.removeAt(0) }
            // Never let an archive write outside the destination.
            if (components.contains("..") || components.isEmpty()) continue
            val target = components.fold(into) { dir, part -> File(dir, part) }

            when (typeFlag) {
                '5'.code -> target.mkdirs()
                0, '0'.code, '7'.code -> {
                    target.parentFile?.mkdirs()
                    target.writeBytes(content)
                }
                '2'.code -> {
                    val linkTarget = field(header, 157, 100)
                    target.parentFile?.mkdirs()
                    target.delete()
                    runCatching { Files.createSymbolicLink(target.toPath(), Paths.get(linkTarget)) }
                }
                // hardlinks, fifos, devices: skip
            }
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
