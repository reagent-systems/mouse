package com.reagentsystems.mouse.node

import com.reagentsystems.mouse.packages.Json
import java.io.IOException
import java.nio.file.FileAlreadyExistsException
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.Path
import java.nio.file.Paths
import java.nio.file.StandardOpenOption
import java.nio.file.attribute.FileTime
import java.nio.file.attribute.PosixFilePermission
import java.util.Base64

/**
 * The Node layer's filesystem, and the workspace-virtual paths it speaks.
 *
 * ## What this is and is not
 *
 * This is the Android half of `NodeEngine.swift`'s `readFile`/`writeFile`/`stat`/`readdir`/
 * `mkdir`/`remove`/`rename`/`chmodPath`/`statfs` blocks — the PRIMITIVES, and only those. Every
 * piece of node's fs *semantics* — ENOENT for a missing parent, EISDIR for reading a directory,
 * EEXIST, ENOTDIR, refusing to delete a tree without `recursive` — lives in the shared JavaScript
 * bootstrap, which Android runs verbatim. So the whole of that hard-won strictness
 * (AGENTS.md: "a permissive filesystem API destroys data or invents it") comes across for free,
 * and what has to be right here is much smaller: each primitive must answer exactly what the
 * Swift block answers, including WHEN IT ANSWERS NOTHING. A `null` is how every one of those
 * failures is reported upward, so a primitive that succeeds where Swift's fails, or invents a
 * value where Swift's returns null, silently disables a rule written somewhere else.
 *
 * That is why this module is pure JVM rather than part of `:app`: it is gradeable, and
 * `:nodecheck` grades it against a real temporary directory.
 *
 * ## Workspace-virtual paths
 *
 * A program sees a filesystem rooted at "/" and never learns where that really is — the same
 * discipline as iOS, and on Android the same necessity: app-private storage lives at a path the
 * user has no name for. "/a/b" and "a/b" are the same place, ".." clamps at the root rather than
 * escaping it, and [mount] grafts a real directory in at a virtual prefix.
 *
 * ## Marshalling
 *
 * iOS returns Swift dictionaries and arrays; JavaScriptCore converts them. Android's
 * `@JavascriptInterface` carries only primitives and strings, so the structured answers cross as
 * JSON and `node-host.js` parses them back into the shapes the bootstrap already expects. File
 * CONTENT crosses as base64, exactly as it does on iOS — the bootstrap does
 * `Buffer.from(base64, 'base64')` either way, so binary survives.
 */
class NodeFs(root: Path) {

    /** The real directory the virtual root maps to. */
    val root: Path = root.toAbsolutePath().normalize()

    private val mounts = ArrayList<Pair<String, Path>>()

    /**
     * Graft [real] in at the virtual path [prefix].
     *
     * A mount prefix is always absolute and never trailing-slashed, so matching one is a plain
     * string test at every call site rather than a special case per call site — the same
     * normalisation `NodeEngine.normalizeMountPrefix` performs.
     */
    fun mount(prefix: String, real: Path) {
        var text = if (prefix.startsWith("/")) prefix else "/$prefix"
        while (text.length > 1 && text.endsWith("/")) text = text.dropLast(1)
        mounts.add(text to real.toAbsolutePath().normalize())
    }

    // ------------------------------------------------------------------------ paths ----

    /** "/a/b" and "a/b" both live under the root; ".." clamps at "/". */
    fun normalize(path: String): String {
        val parts = ArrayList<String>()
        for (piece in path.split("/")) {
            if (piece.isEmpty() || piece == ".") continue
            if (piece == "..") {
                if (parts.isNotEmpty()) parts.removeAt(parts.size - 1)
                continue
            }
            parts.add(piece)
        }
        return "/" + parts.joinToString("/")
    }

    /** The directory a virtual path sits in. "/" is its own parent. */
    fun virtualDirname(path: String): String {
        val normalized = normalize(path)
        val slash = normalized.lastIndexOf('/')
        if (slash <= 0) return "/"
        return normalized.substring(0, slash)
    }

    /** Virtual → real. Mounts first, then the root. */
    fun realPath(path: String): Path {
        val normalized = normalize(path)
        for ((prefix, real) in mounts) {
            if (normalized == prefix) return real
            if (normalized.startsWith("$prefix/")) {
                return real.resolve(normalized.substring(prefix.length + 1))
            }
        }
        return if (normalized == "/") root else root.resolve(normalized.substring(1))
    }

    // -------------------------------------------------------------------- primitives ----

    /** File content as base64, or null when it cannot be read — a directory included. */
    fun readFile(path: String): String? = try {
        val real = realPath(path)
        // Reading a directory is EISDIR on a real syscall and an error from `Data(contentsOf:)`;
        // some JDK/OS pairs will happily hand back its raw bytes instead, which would turn the
        // bootstrap's EISDIR branch into a Buffer full of nonsense.
        if (Files.isDirectory(real)) null
        else Base64.getEncoder().encodeToString(Files.readAllBytes(real))
    } catch (_: Exception) {
        null
    }

    /** The same content as text, for the module loader. Null when unreadable or not UTF-8. */
    fun readText(path: String): String? = try {
        val real = realPath(path)
        if (Files.isDirectory(real)) null else String(Files.readAllBytes(real), Charsets.UTF_8)
    } catch (_: Exception) {
        null
    }

    /**
     * Write [base64] to [path]. Appends when asked AND the file already exists — which is what
     * `FileHandle(forWritingTo:)` failing on a missing file makes the Swift block do, so an
     * append to a file that is not there creates it rather than failing.
     *
     * The parent directory is created, matching Swift. That looks like the "permissive filesystem
     * API" AGENTS.md warns about and is not: the bootstrap checks `_parentExists` and raises
     * ENOENT itself before ever reaching here, so the strictness is one layer up on both
     * platforms. Moving it down here would diverge from iOS while looking like a fix.
     */
    fun writeFile(path: String, base64: String, append: Boolean): Boolean = try {
        val data = Base64.getDecoder().decode(base64)
        val real = realPath(path)
        real.parent?.let { runCatching { Files.createDirectories(it) } }
        if (append && Files.exists(real)) {
            Files.write(real, data, StandardOpenOption.WRITE, StandardOpenOption.APPEND)
        } else {
            Files.write(real, data)
        }
        true
    } catch (_: Exception) {
        false
    }

    /**
     * The FULL stat, as the bootstrap's `statsFrom` reads it. `mode` is not a luxury — chokidar
     * gates every entry on `4 & parseInt(stats.mode, 10)`, so a Stats without one reads as "not
     * readable" and silently hides every file in a watched tree.
     *
     * [followLinks] false is `lstat(2)`: it must NOT follow, and `isSymbolicLink()` must be able
     * to answer true.
     */
    fun stat(path: String, followLinks: Boolean): Map<String, Any?>? {
        val real = realPath(path)
        val options = if (followLinks) emptyArray<LinkOption>() else arrayOf(LinkOption.NOFOLLOW_LINKS)
        // `unix:*` is the whole of stat(2) in one read and is what a JDK on a POSIX host offers.
        // Where it is missing the posix view still carries type, size, times and permissions, and
        // the identity fields are derived rather than invented — see the nuance note in
        // kotlin/README.md for which ones are approximations.
        val attributes: Map<String, Any?> = try {
            Files.readAttributes(real, "unix:*", *options)
        } catch (_: Exception) {
            try {
                Files.readAttributes(real, "posix:*", *options)
            } catch (_: Exception) {
                try {
                    Files.readAttributes(real, "basic:*", *options)
                } catch (_: Exception) {
                    return null
                }
            }
        }

        val isDirectory = attributes["isDirectory"] == true
        val isLink = attributes["isSymbolicLink"] == true
        val isFile = attributes["isRegularFile"] == true
        val size = (attributes["size"] as? Number)?.toLong() ?: 0L

        @Suppress("UNCHECKED_CAST")
        val permissions = attributes["permissions"] as? Set<PosixFilePermission>
        val mode = (attributes["mode"] as? Number)?.toInt()
            ?: (typeBits(isDirectory, isLink, isFile) or permissionBits(permissions))

        fun millis(key: String): Double =
            ((attributes[key] as? FileTime)?.toMillis() ?: 0L).toDouble()

        val modified = millis("lastModifiedTime")
        val changed = (attributes["ctime"] as? FileTime)?.toMillis()?.toDouble() ?: modified
        val blockSize = 4096
        return mapOf(
            "dir" to isDirectory,
            "link" to isLink,
            "file" to isFile,
            "size" to size.toDouble(),
            "mode" to mode,
            "uid" to ((attributes["uid"] as? Number)?.toInt() ?: 0),
            "gid" to ((attributes["gid"] as? Number)?.toInt() ?: 0),
            "ino" to ((attributes["ino"] as? Number)?.toDouble() ?: fileKeyIno(attributes)),
            "dev" to ((attributes["dev"] as? Number)?.toInt() ?: 0),
            "nlink" to ((attributes["nlink"] as? Number)?.toInt() ?: 1),
            "rdev" to ((attributes["rdev"] as? Number)?.toInt() ?: 0),
            // st_blocks and st_blksize have no JDK spelling. Derived from the size in 512-byte
            // units, which is the unit stat(2) reports them in.
            "blocks" to ((size + 511) / 512).toDouble(),
            "blksize" to blockSize,
            "mtimeMs" to modified,
            "atimeMs" to millis("lastAccessTime"),
            "ctimeMs" to changed,
            "birthtimeMs" to millis("creationTime"),
        )
    }

    /** Directory entries, sorted, or null when [path] is not a readable directory. */
    fun readdir(path: String): List<String>? {
        val real = realPath(path)
        if (!Files.isDirectory(real)) return null
        return try {
            Files.newDirectoryStream(real).use { stream ->
                stream.map { it.fileName.toString() }.sorted()
            }
        } catch (_: IOException) {
            null
        }
    }

    /** Create [path] and every missing parent. Already being a directory is success. */
    fun mkdir(path: String): Boolean = try {
        Files.createDirectories(realPath(path))
        true
    } catch (_: Exception) {
        false
    }

    /** Delete [path], a whole tree included. False when there is nothing there. */
    fun remove(path: String): Boolean {
        val real = realPath(path)
        if (!Files.exists(real, LinkOption.NOFOLLOW_LINKS)) return false
        return try {
            removeRecursively(real)
            true
        } catch (_: Exception) {
            false
        }
    }

    private fun removeRecursively(target: Path) {
        // A symlink to a directory is deleted as the LINK, never walked — walking it would
        // delete somebody else's tree.
        if (Files.isDirectory(target, LinkOption.NOFOLLOW_LINKS)) {
            Files.newDirectoryStream(target).use { stream ->
                for (child in stream) removeRecursively(child)
            }
        }
        Files.deleteIfExists(target)
    }

    /** Move. Fails when the destination already exists, as `moveItem` does. */
    fun rename(from: String, to: String): Boolean = try {
        Files.move(realPath(from), realPath(to))
        true
    } catch (_: FileAlreadyExistsException) {
        false
    } catch (_: Exception) {
        false
    }

    /**
     * chmod. Only the nine permission bits travel: the JDK's posix view has no spelling for
     * setuid/setgid/sticky, and inventing one is not available. The case this exists for — a
     * program writing a secret with `mode: 0o600` and getting a world-readable file — is
     * entirely within those nine.
     */
    fun chmod(path: String, mode: Int): Boolean = try {
        Files.setPosixFilePermissions(realPath(path), permissionsFrom(mode))
        true
    } catch (_: Exception) {
        false
    }

    /**
     * statfs(2)'s free space and block counts. Build tools check available space before writing
     * large artifacts, and node exports it.
     *
     * `type`, `files` and `ffree` have no JDK spelling and answer 0 — recorded in
     * kotlin/README.md rather than faked into something that looks measured.
     *
     * TWO PATHS, and the second one is why this works on a phone at all.
     * `Files.getFileStore` reports a real block size, so it is tried first and is what the JVM
     * gate measures. On Android it throws: resolving a `FileStore` means matching the path against
     * the mount table, and an app cannot read enough of `/proc/mounts` to do it. Returning null
     * there made the bootstrap raise `ENOENT: statfs '/'` — which killed the whole program on the
     * first fs call and took 30 downstream device checks with it, while the desktop harness stayed
     * green. `File`'s space methods need no mount table and work everywhere.
     *
     * A MISSING path still returns null, so a genuine ENOENT stays a genuine ENOENT — the
     * existence check is what separates "no such directory" from "this platform has no FileStore".
     */
    fun statfs(path: String): Map<String, Any?>? {
        val resolved = try { realPath(path) } catch (_: Exception) { return null }
        val file = resolved.toFile()
        if (!file.exists()) return null
        val store = try { Files.getFileStore(resolved) } catch (_: Exception) { null }
        // 4096 is the fallback, not a measurement: it is what the JDK itself reports for every
        // filesystem Android ships, and the alternative is refusing to answer at all.
        val blockSize = store?.blockSize?.takeIf { it > 0 } ?: 4096L
        val total = store?.totalSpace ?: file.totalSpace
        val free = store?.unallocatedSpace ?: file.freeSpace
        val usable = store?.usableSpace ?: file.usableSpace
        return mapOf(
            "type" to 0,
            "bsize" to blockSize.toDouble(),
            "blocks" to (total / blockSize).toDouble(),
            "bfree" to (free / blockSize).toDouble(),
            "bavail" to (usable / blockSize).toDouble(),
            "files" to 0.0,
            "ffree" to 0.0,
        )
    }

    // ------------------------------------------------------------------ marshalling ----

    /** [stat] as the JSON `node-host.js` parses, or null — which crosses the bridge as null. */
    fun statJson(path: String, followLinks: Boolean): String? =
        stat(path, followLinks)?.let { Json.write(it) }

    /** [readdir] as JSON. */
    fun readdirJson(path: String): String? = readdir(path)?.let { Json.write(it) }

    /** [statfs] as JSON. */
    fun statfsJson(path: String): String? = statfs(path)?.let { Json.write(it) }

    // ----------------------------------------------------------------------- detail ----

    private fun typeBits(isDirectory: Boolean, isLink: Boolean, isFile: Boolean): Int = when {
        isDirectory -> S_IFDIR
        isLink -> S_IFLNK
        isFile -> S_IFREG
        else -> 0
    }

    private fun permissionBits(permissions: Set<PosixFilePermission>?): Int {
        if (permissions == null) return DEFAULT_PERMISSIONS
        var bits = 0
        for (permission in permissions) {
            bits = bits or when (permission) {
                PosixFilePermission.OWNER_READ -> 0x100
                PosixFilePermission.OWNER_WRITE -> 0x080
                PosixFilePermission.OWNER_EXECUTE -> 0x040
                PosixFilePermission.GROUP_READ -> 0x020
                PosixFilePermission.GROUP_WRITE -> 0x010
                PosixFilePermission.GROUP_EXECUTE -> 0x008
                PosixFilePermission.OTHERS_READ -> 0x004
                PosixFilePermission.OTHERS_WRITE -> 0x002
                PosixFilePermission.OTHERS_EXECUTE -> 0x001
            }
        }
        return bits
    }

    private fun permissionsFrom(mode: Int): MutableSet<PosixFilePermission> {
        val out = HashSet<PosixFilePermission>()
        if (mode and 0x100 != 0) out.add(PosixFilePermission.OWNER_READ)
        if (mode and 0x080 != 0) out.add(PosixFilePermission.OWNER_WRITE)
        if (mode and 0x040 != 0) out.add(PosixFilePermission.OWNER_EXECUTE)
        if (mode and 0x020 != 0) out.add(PosixFilePermission.GROUP_READ)
        if (mode and 0x010 != 0) out.add(PosixFilePermission.GROUP_WRITE)
        if (mode and 0x008 != 0) out.add(PosixFilePermission.GROUP_EXECUTE)
        if (mode and 0x004 != 0) out.add(PosixFilePermission.OTHERS_READ)
        if (mode and 0x002 != 0) out.add(PosixFilePermission.OTHERS_WRITE)
        if (mode and 0x001 != 0) out.add(PosixFilePermission.OTHERS_EXECUTE)
        return out
    }

    /** An inode number when the platform will not name one: the file key's own identity. */
    private fun fileKeyIno(attributes: Map<String, Any?>): Double {
        val key = attributes["fileKey"] ?: return 0.0
        // Kept inside 2^53 so it stays an exact integer after the JSON hop.
        return (key.hashCode().toLong() and 0xffffffffL).toDouble()
    }

    companion object {
        private const val S_IFDIR = 0x4000
        private const val S_IFREG = 0x8000
        private const val S_IFLNK = 0xa000

        /** `rw-r--r--` plus a regular file's type bits: what a POSIX-less view can honestly say. */
        private const val DEFAULT_PERMISSIONS = 0x1a4

        /** Convenience for a host that keeps its workspace at a plain path. */
        fun at(path: String): NodeFs = NodeFs(Paths.get(path))
    }
}
