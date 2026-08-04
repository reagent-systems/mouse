package com.reagentsystems.mouse.packages

import java.io.File
import java.net.HttpURLConnection
import java.net.URI
import java.security.MessageDigest

/**
 * Language runtimes that arrive as WebAssembly. A port of `swift/Mouse/Runtimes.swift`, reading
 * the SAME `swift/Runtimes.json` — the catalog is data, and one file for both platforms is the
 * only way the parity claim stays falsifiable.
 *
 * The rule this file exists to keep: a runtime is DOWNLOADED, never bundled. Shipping CPython
 * inside the APK would add ~45 MB to every install for a language most projects never touch, and
 * would freeze its version to whenever the app was last released. `pkg install python` fetches
 * the official wasm32-wasi build, checks it against a recorded hash, and unpacks it into the
 * app's files directory — never the cache, because Android may evict caches under pressure and a
 * language silently disappearing mid-project is worse than the disk it costs.
 *
 * On Android this rule is not merely a preference, it is the only door: since API 29 an app
 * targeting 29+ cannot exec a binary out of its own writable data directory, and this app targets
 * 35. Downloaded NATIVE binaries are impossible; downloaded wasm is not, because nothing execs it
 * — the phase-G engine interprets it.
 *
 * What runs the artifact is that engine's `node:wasi`, which is milestone 3. This file is the
 * half that can land before it: fetch, verify, unpack, list, remove.
 */
object RuntimeCatalog {
    enum class Archive(val id: String) {
        ZIP("zip"),
        TAR_GZ("tar.gz"),
        ;

        companion object {
            fun of(id: String): Archive? = entries.firstOrNull { it.id == id }
        }
    }

    data class Entry(
        val name: String,
        val version: String,
        val url: String,
        /**
         * The download's size and SHA-256. The size is what the install line quotes before it
         * starts; the hash is what makes the install refuse a corrupted or substituted archive.
         */
        val downloadBytes: Long,
        val sha256: String,
        /**
         * How the download unpacks, and how many leading path components to drop while it does
         * (release tarballs wrap their content in a versioned directory; the zips here are flat).
         */
        val archive: Archive,
        val strip: Int?,
        /**
         * The interpreter inside the unpacked archive, and the directory its standard library
         * lives in — both relative to the runtime's install directory.
         */
        val wasm: String,
        val library: String?,
        /**
         * The command names this runtime answers to at the prompt (`python` and `python3` are one
         * interpreter). The catalog knows them for UNINSTALLED runtimes too, which is what lets
         * the shell answer "not installed" instead of "command not found".
         */
        val commands: List<String>,
        /**
         * The interpreter's environment. `{root}` expands to the runtime's mount path
         * (`/usr/lib/<name>`) at launch, so an entry can name its own stdlib without knowing where
         * installs live.
         */
        val env: Map<String, String>,
        /**
         * Whether bare script arguments are rewritten to absolute virtual paths before launch.
         * WASI interpreters have no cwd of their own, so `python hello.py` only works if the shell
         * turns `hello.py` into `/hello.py` — flags and inline code stay untouched.
         */
        val rewriteScriptPaths: Boolean,
        /** A one-line description of what the runtime is, for `pkg list`. */
        val summary: String,
    )

    class CatalogError(message: String) : Exception(message)

    /**
     * Parse the catalog. A malformed entry THROWS rather than being skipped: a silently dropped
     * runtime shows up as "command not found" for a language the catalog plainly lists, which is
     * the least debuggable failure this layer can produce.
     */
    fun parse(text: String): List<Entry> {
        val root = Json.parseObjectOrNull(text) ?: throw CatalogError("the catalog is not a JSON object")
        val runtimes = root["runtimes"] as? List<*> ?: throw CatalogError("the catalog has no `runtimes` array")
        return runtimes.map { element ->
            val entry = element.asObject() ?: throw CatalogError("a catalog entry is not an object")
            fun string(key: String): String =
                entry[key].asString() ?: throw CatalogError("a catalog entry has no `$key`")
            val name = string("name")
            val archiveId = string("archive")
            Entry(
                name = name,
                version = string("version"),
                url = string("url"),
                downloadBytes = (entry["downloadBytes"] as? Number)?.toLong()
                    ?: throw CatalogError("$name has no `downloadBytes`"),
                sha256 = string("sha256"),
                archive = Archive.of(archiveId)
                    ?: throw CatalogError("$name declares archive `$archiveId`, which is not zip or tar.gz"),
                strip = (entry["strip"] as? Number)?.toInt(),
                wasm = string("wasm"),
                library = entry["library"].asString(),
                commands = (entry["commands"] as? List<*>)?.mapNotNull { it.asString() }
                    ?: throw CatalogError("$name has no `commands`"),
                env = entry["env"].asStringMap(),
                rewriteScriptPaths = entry["rewriteScriptPaths"] as? Boolean ?: false,
                summary = string("summary"),
            )
        }
    }

    fun entry(entries: List<Entry>, name: String): Entry? = entries.firstOrNull { it.name == name }

    /** The entry that answers to a typed command — installed or not. */
    fun forCommand(entries: List<Entry>, command: String): Entry? =
        entries.firstOrNull { command in it.commands }
}

/**
 * Where installed runtimes live, and how they get there.
 *
 * Unlike the iOS original this takes its base directory as a parameter instead of reaching for
 * one: `:packages` is a pure-JVM module with no `android.*` on its classpath (that is what makes
 * it gatable without an emulator), so it cannot ask a `Context` for `filesDir`. The app passes it
 * in; the harness passes a temp directory.
 */
class RuntimeStore(base: File) {
    /**
     * On disk the store is `MouseRuntimes/usr/lib/<name>`, and the shell mounts the whole `usr`
     * directory at `/usr`. The extra two levels are not decoration: an interpreter that
     * canonicalizes its load paths (realpath) walks `/usr`, then `/usr/lib`, then
     * `/usr/lib/<name>` component by component, and a component that exists only as a mount-table
     * prefix answers ENOENT. With the layout mirrored on disk, every ancestor a runtime names is
     * a real directory.
     */
    val usr: File = File(base, "MouseRuntimes/usr")
    val root: File = File(usr, "lib")

    init {
        root.mkdirs()
    }

    data class Installed(
        val name: String,
        val version: String,
        val directory: File,
        val wasm: File,
        val library: File?,
    )

    fun installed(entry: RuntimeCatalog.Entry): Installed? {
        val directory = File(root, entry.name)
        val wasm = File(directory, entry.wasm)
        if (!wasm.isFile) return null
        return Installed(
            name = entry.name,
            version = entry.version,
            directory = directory,
            wasm = wasm,
            library = entry.library?.let { File(directory, it) },
        )
    }

    fun installedNames(entries: List<RuntimeCatalog.Entry>): List<String> =
        entries.filter { installed(it) != null }.map { it.name }

    sealed class InstallError(message: String) : Exception(message) {
        class Download(why: String) : InstallError("download failed: $why")

        /**
         * Naming both hashes matters: it separates "the network mangled it" from "this is not the
         * archive we recorded", and only the second is alarming.
         */
        class Integrity(expected: String, got: String) : InstallError(
            "the download does not match its recorded hash\n  expected $expected\n  got      $got",
        )

        class Unpack(why: String) : InstallError("could not unpack the archive: $why")
        class MissingInterpreter(name: String) : InstallError("the archive did not contain $name")
    }

    /**
     * Download, verify, unpack, reporting progress as it goes — a multi-megabyte download with no
     * output is indistinguishable from a hang. Runs wherever the caller puts it; the caller is
     * responsible for keeping it off the main thread (a 30 MB inflate has no business on the UI
     * thread), which on iOS the compiler enforces and here it cannot.
     */
    fun install(
        entry: RuntimeCatalog.Entry,
        note: (String) -> Unit = {},
        fetch: (String) -> ByteArray = ::download,
    ) {
        note("fetching ${entry.name} ${entry.version} (${entry.downloadBytes / 1_000_000} MB)")
        val data = try {
            fetch(entry.url)
        } catch (e: InstallError) {
            throw e
        } catch (e: Exception) {
            throw InstallError.Download(e.message ?: e.toString())
        }

        val digest = MessageDigest.getInstance("SHA-256").digest(data)
            .joinToString("") { "%02x".format(it) }
        if (digest != entry.sha256) throw InstallError.Integrity(entry.sha256, digest)

        val directory = File(root, entry.name)
        // A half-written runtime is worse than none: unpack beside the target and swap, so an
        // interrupted install leaves the previous one intact.
        val staging = File(root, ".${entry.name}.incoming")
        staging.deleteRecursively()
        staging.mkdirs()
        try {
            // Both unpackers refuse entries that escape the destination (`..`, absolute names) —
            // an archive is a download, and a download must not write outside its directory.
            when (entry.archive) {
                RuntimeCatalog.Archive.ZIP -> ZipArchive.extract(data, staging)
                RuntimeCatalog.Archive.TAR_GZ -> TarGz.extract(data, staging, entry.strip ?: 0)
            }
        } catch (e: Exception) {
            staging.deleteRecursively()
            throw InstallError.Unpack(e.message ?: e.toString())
        }
        if (!File(staging, entry.wasm).isFile) {
            staging.deleteRecursively()
            throw InstallError.MissingInterpreter(entry.wasm)
        }
        directory.deleteRecursively()
        if (!staging.renameTo(directory)) {
            staging.deleteRecursively()
            throw InstallError.Unpack("could not move the unpacked runtime into place")
        }
        note("installed ${entry.name} ${entry.version}")
    }

    fun remove(entry: RuntimeCatalog.Entry): Boolean {
        val directory = File(root, entry.name)
        if (!directory.isDirectory) return false
        return directory.deleteRecursively()
    }

    companion object {
        /**
         * The default transport, and public so the gate can drive it directly: a harness that
         * substituted its own download would leave the redirect handling below ungated, and that
         * is precisely the part with a failure mode.
         *
         * Redirects are followed BY HAND. `HttpURLConnection` refuses to follow one that changes
         * protocol, and every release artifact in the catalog is a GitHub URL that redirects to a
         * separate object host — so an automatic follow can land on a 302 body, and the hash check
         * would then report a mismatch for something that was never the archive.
         */
        fun download(url: String): ByteArray {
            var target = url
            for (hop in 0 until 5) {
                val connection = (URI(target).toURL().openConnection() as HttpURLConnection).apply {
                    requestMethod = "GET"
                    connectTimeout = 30_000
                    readTimeout = 120_000
                    instanceFollowRedirects = false
                }
                try {
                    val status = connection.responseCode
                    if (status in 300..399) {
                        target = connection.getHeaderField("Location")
                            ?: throw InstallError.Download("HTTP $status with no Location header")
                        continue
                    }
                    if (status !in 200..299) throw InstallError.Download("HTTP $status")
                    return connection.inputStream.use { it.readBytes() }
                } finally {
                    connection.disconnect()
                }
            }
            throw InstallError.Download("too many redirects")
        }
    }
}

/**
 * A reader for the ZIP format, because Android's framework unzip is `java.util.zip`, whose
 * `ZipInputStream` cannot be trusted with an archive that has no usable local headers — and,
 * more to the point, because an archive is a DOWNLOAD and refusing entries that escape their
 * directory is the whole reason to parse rather than hand it to something that will not.
 *
 * Only what an unpack needs: walk the central directory, then copy stored entries and inflate
 * deflated ones. The inflate is `TarGz.inflateRaw`, the same raw-DEFLATE path npm tarballs use,
 * which is exactly what a zip entry holds. A port of `ZipArchive` in `swift/Mouse/Runtimes.swift`.
 */
object ZipArchive {
    class FormatError(message: String) : Exception(message)

    fun extract(data: ByteArray, destination: File) {
        val end = endOfCentralDirectory(data)
            ?: throw FormatError("no end-of-central-directory record — not a zip")
        var offset = end.centralDirectoryOffset

        for (index in 0 until end.entryCount) {
            if (offset + 46 > data.size || read32(data, offset) != 0x02014b50L) {
                throw FormatError("central directory entry is malformed")
            }
            val method = read16(data, offset + 10)
            val compressedSize = read32(data, offset + 20).toInt()
            val uncompressedSize = read32(data, offset + 24).toInt()
            val nameLength = read16(data, offset + 28)
            val extraLength = read16(data, offset + 30)
            val commentLength = read16(data, offset + 32)
            val localOffset = read32(data, offset + 42).toInt()
            if (offset + 46 + nameLength > data.size) {
                throw FormatError("entry name runs past the end of the archive")
            }
            val name = String(data, offset + 46, nameLength, Charsets.UTF_8)
            offset += 46 + nameLength + extraLength + commentLength

            // An entry naming `..` or an absolute path can write anywhere on disk.
            val components = name.split("/").filter { it.isNotEmpty() }
            if (name.startsWith("/") || components.contains("..")) {
                throw FormatError("archive entry escapes its directory: $name")
            }
            val target = components.fold(destination) { parent, component -> File(parent, component) }
            if (name.endsWith("/")) {
                target.mkdirs()
                continue
            }

            if (localOffset + 30 > data.size || read32(data, localOffset) != 0x04034b50L) {
                throw FormatError("local header for $name is malformed")
            }
            // The local header repeats the name and extra-field lengths, and its own extra field
            // is frequently a different length from the central directory's — reading the central
            // one here lands in the middle of the data.
            val localNameLength = read16(data, localOffset + 26)
            val localExtraLength = read16(data, localOffset + 28)
            val start = localOffset + 30 + localNameLength + localExtraLength
            if (start + compressedSize > data.size) {
                throw FormatError("data for $name runs past the end of the archive")
            }
            val payload = data.copyOfRange(start, start + compressedSize)

            val contents = when (method) {
                0 -> payload
                8 -> TarGz.inflateRaw(payload)
                else -> throw FormatError(
                    "$name uses compression method $method, which is not deflate or stored",
                )
            }
            if (contents.size != uncompressedSize) {
                throw FormatError(
                    "$name unpacked to ${contents.size} bytes, not the $uncompressedSize it declares",
                )
            }
            target.parentFile?.mkdirs()
            target.writeBytes(contents)
        }
    }

    private class EndRecord(val entryCount: Int, val centralDirectoryOffset: Int)

    /**
     * The EOCD sits at the end, after a comment of unknown length, so it is found by scanning
     * backwards for its signature.
     */
    private fun endOfCentralDirectory(data: ByteArray): EndRecord? {
        if (data.size < 22) return null
        var index = data.size - 22
        val floor = maxOf(0, data.size - 22 - 0xffff)
        while (index >= floor) {
            if (read32(data, index) == 0x06054b50L) {
                return EndRecord(read16(data, index + 10), read32(data, index + 16).toInt())
            }
            index -= 1
        }
        return null
    }

    private fun read16(data: ByteArray, at: Int): Int {
        if (at + 2 > data.size) return 0
        return (data[at].toInt() and 0xFF) or ((data[at + 1].toInt() and 0xFF) shl 8)
    }

    /** Unsigned: a zip offset past 2 GB is still a valid `Int` here only because we check it. */
    private fun read32(data: ByteArray, at: Int): Long {
        if (at + 4 > data.size) return 0
        return (data[at].toLong() and 0xFF) or
            ((data[at + 1].toLong() and 0xFF) shl 8) or
            ((data[at + 2].toLong() and 0xFF) shl 16) or
            ((data[at + 3].toLong() and 0xFF) shl 24)
    }
}
