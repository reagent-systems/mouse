package com.reagentsystems.mouse.packages

import java.io.File
import java.net.HttpURLConnection
import java.net.URI
import java.security.MessageDigest
import java.util.Base64

/**
 * The package manager (system.md phase F), ported from `swift/Mouse/PackageManager.swift`:
 * resolve npm packages from the registry, verify and unpack their tarballs (native `TarGz`), lay
 * out a Node-compatible `node_modules` tree, and record executables.
 *
 * Platform-free by design, the way the Swift one is Foundation-only: resolution verifies
 * headlessly against a real `pnpm install --lockfile-only`, and the installed tree against real
 * `node` resolving it (per AGENTS.md). Running the installed JavaScript is phase G's job — this
 * phase makes `node_modules` and `$PATH` truthful.
 *
 * The API is BLOCKING, unlike the Swift one's `async`. That is the Kotlin app's existing house
 * style for network work (`GitHub.kt`, `Workspace.fetchAndExtract`): callers wrap it in
 * `withContext(Dispatchers.IO)`. It also keeps this module free of kotlinx-coroutines, which is
 * an `:app` dependency and has no business in a gate that must run on a bare JVM.
 */
object PackageManager {

    class PackageError(message: String) : Exception(message)

    // MARK: - Registry

    class ResolvedPackage(
        val name: String,
        val version: String,
        val tarball: String,
        val integrity: String?,
        val shasum: String?,
        val dependencies: Map<String, String>,
        /**
         * The per-platform binaries a package publishes. All of them are skipped except one:
         * see [wasiBinding].
         */
        val optionalDependencies: Map<String, String>,
        val bin: Map<String, String>,
    )

    /** One HTTP answer. Status is kept so 404 can be told apart from a registry outage. */
    class HttpResponse(val status: Int, val body: ByteArray)

    /** One resolution session: packument cache + the chosen set. */
    class Session(
        val registry: String = "https://registry.npmjs.org",
        /**
         * The single HTTP seam. The app leaves it at the default; the verify harness wraps it so
         * immutable tarballs come out of `~/.cache/mouse-verify` on a rerun instead of off the
         * network again. Packuments are deliberately NOT cacheable that way — they change when
         * someone publishes, and a resolver answering from yesterday's copy would disagree with
         * the live pnpm it is graded against.
         */
        val transport: (String, Map<String, String>) -> HttpResponse = PackageManager::httpGet,
    ) {
        private val packuments = HashMap<String, Map<String, Any?>>()

        fun packument(name: String): Map<String, Any?> {
            packuments[name]?.let { return it }
            val encoded = name.replace("/", "%2F")
            // The abbreviated document: versions, deps, dist — an order of magnitude smaller.
            val response = transport(
                "$registry/$encoded",
                mapOf("Accept" to "application/vnd.npm.install-v1+json"),
            )
            if (response.status != 200) {
                throw PackageError(
                    if (response.status == 404) "package not found: $name"
                    else "registry returned ${response.status} for $name",
                )
            }
            val json = Json.parseObjectOrNull(String(response.body, Charsets.UTF_8))
                ?: throw PackageError("bad registry response for $name")
            packuments[name] = json
            return json
        }

        /**
         * Highest version satisfying the range (the npm rule). "latest"-style dist-tags resolve
         * through `dist-tags` first.
         */
        fun resolve(name: String, requirement: String): ResolvedPackage {
            // An ALIAS: `"local-name": "npm:real-name@range"` installs one package under a
            // different directory name, and a tree may depend on two versions of the same
            // package that way. Taking the alias to the registry asks for a package nobody
            // published — n8n's tree does exactly this, and the 404 failed the whole install.
            var realName = name
            var wanted = requirement.trim()
            if (wanted.startsWith("npm:")) {
                val spec = wanted.substring(4)
                // The version separator is the LAST '@' that is not the scope's leading one,
                // so `npm:@scope/pkg@^1` splits after the package name, not inside the scope.
                val searchStart = if (spec.startsWith("@")) 1 else 0
                val at = spec.lastIndexOf('@')
                if (at >= searchStart) {
                    realName = spec.substring(0, at)
                    wanted = spec.substring(at + 1)
                } else {
                    realName = spec
                    wanted = "*"
                }
                if (wanted.isEmpty()) wanted = "*"
            }
            val packument = packument(realName)
            val versions = packument["versions"].asObject() ?: emptyMap()
            if (wanted.isEmpty()) wanted = "*"
            packument["dist-tags"].asStringMap()[wanted]?.let { wanted = it }
            val range = SemverRange.parse(wanted)
                ?: throw PackageError("$realName: unsupported version range '$wanted'")
            var best: Semver? = null
            var chosen: String? = null
            for (versionText in versions.keys) {
                val version = Semver.parse(versionText) ?: continue
                if (!range.satisfiedBy(version)) continue
                val incumbent = best
                if (incumbent == null || version > incumbent) { best = version; chosen = versionText }
            }
            val picked = chosen ?: throw PackageError("$realName: no version satisfies '$wanted'")
            val meta = versions[picked].asObject()
                ?: throw PackageError("$realName: no version satisfies '$wanted'")
            return packageOf(realName, picked, meta)
        }

        private fun packageOf(name: String, version: String, meta: Map<String, Any?>): ResolvedPackage {
            val dist = meta["dist"].asObject() ?: emptyMap()
            var bins: Map<String, String> = emptyMap()
            val bin = meta["bin"]
            if (bin is String) {
                // A lone string names the package itself.
                val short = name.split("/").last()
                bins = mapOf(short to bin)
            } else if (bin != null) {
                bins = bin.asStringMap()
            }
            return ResolvedPackage(
                name = name,
                version = version,
                tarball = dist["tarball"].asString() ?: "",
                integrity = dist["integrity"].asString(),
                shasum = dist["shasum"].asString(),
                dependencies = meta["dependencies"].asStringMap(),
                optionalDependencies = meta["optionalDependencies"].asStringMap(),
                bin = bins,
            )
        }
    }

    // MARK: - Resolution (the whole tree)

    /**
     * Breadth-first resolution with classic npm hoisting: first requirement of a name lands at
     * the root; a conflicting version nests under its dependent. Returns every placement.
     */
    class Placement(
        val pkg: ResolvedPackage,
        /**
         * Directory relative to the project root, e.g. "node_modules/chalk" or
         * "node_modules/chalk/node_modules/supports-color".
         */
        val path: String,
        /**
         * The name this package was REQUESTED as, when it stands in for one — `rollup` for
         * `@rollup/wasm-node`. null when the package is itself.
         */
        val installedAs: String? = null,
    ) {
        /** Whether this placement sits at the root of node_modules (its bins join .bin). */
        val atRoot: Boolean get() = !path.removePrefix("node_modules/").contains("/")
    }

    /**
     * Packages whose npm release is a per-platform NATIVE binary, mapped to the WebAssembly build
     * their own authors publish for platforms they ship no binary for. iOS is such a platform and
     * always will be: it can neither dlopen a `.node` addon nor exec a downloaded executable.
     * Android is one too, for a different reason with the same effect — since API 29 an app
     * targeting 29+ cannot exec a file out of its own writable data directory, and this app
     * targets 35. The substitute is installed under the ORIGINAL name, so the package that
     * depends on it is unmodified and never learns the difference.
     */
    val wasmSubstitutes: Map<String, String> = mapOf(
        "rollup" to "@rollup/wasm-node",
        "esbuild" to "esbuild-wasm",
    )

    /**
     * The same idea as [wasmSubstitutes], but for the shape napi-rs uses: a package lists every
     * platform's binary in `optionalDependencies` and its loader tries them in turn, ending at
     * `…-wasm32-wasi` — the author's own portable build, published for platforms they do not ship
     * a binary for. Every native one is skipped here and that one is installed, so the loader's
     * last resort is the one that is present. rolldown, which vite 7 bundles with, is exactly
     * this shape.
     */
    fun wasiBinding(pkg: ResolvedPackage): Pair<String, String>? {
        for ((name, requirement) in pkg.optionalDependencies.entries.sortedBy { it.key }) {
            if (name.endsWith("-wasm32-wasi")) return name to requirement
        }
        return null
    }

    fun resolveTree(requirements: Map<String, String>, session: Session): List<Placement> {
        val placements = ArrayList<Placement>()
        val rootVersions = HashMap<String, String>()
        val queue = ArrayDeque<Triple<String, String, String?>>()
        val seen = HashSet<String>()

        for ((name, requirement) in requirements.entries.sortedBy { it.key }) {
            queue.addLast(Triple(name, requirement, null))
        }

        while (queue.isNotEmpty()) {
            val (name, requirement, dependentPath) = queue.removeFirst()
            // Resolved under the substitute's name, placed under the original's. Both projects
            // version their wasm build in lockstep with the native one, so the requirement
            // carries over unchanged.
            val pkg = session.resolve(wasmSubstitutes[name] ?: name, requirement)

            val path: String
            val existing = rootVersions[name]
            if (existing != null) {
                if (existing == pkg.version) continue           // hoisted copy already serves this
                if (dependentPath == null) continue             // root conflict: first wins
                path = "$dependentPath/node_modules/$name"
                if (seen.contains(path)) continue
            } else {
                rootVersions[name] = pkg.version
                path = "node_modules/$name"
            }
            seen.add(path)
            // "requested as X, is really Y" covers both cases now: a wasm substitute standing in
            // for a native package, and an npm: alias installing one package under another name.
            placements.add(Placement(pkg, path, installedAs = if (pkg.name == name) null else name))
            for ((depName, depRequirement) in pkg.dependencies.entries.sortedBy { it.key }) {
                queue.addLast(Triple(depName, depRequirement, path))
            }
            wasiBinding(pkg)?.let { (wasiName, wasiRequirement) ->
                queue.addLast(Triple(wasiName, wasiRequirement, path))
            }
        }
        return placements
    }

    // MARK: - Install

    class InstallReport(
        val placements: MutableList<Placement> = ArrayList(),
        /** bin name → path relative to root */
        val bins: MutableMap<String, String> = LinkedHashMap(),
    )

    /**
     * Resolve and install [requirements] into [root]. Downloads verify against the registry's
     * integrity (sha512, sha1 fallback) before a byte is unpacked.
     */
    fun install(
        requirements: Map<String, String>,
        into: File,
        session: Session = Session(),
        progress: (String) -> Unit = {},
    ): InstallReport {
        val root = into
        val placements = resolveTree(requirements, session)
        val report = InstallReport()
        report.placements.addAll(placements)
        for (placement in placements) {
            val pkg = placement.pkg
            if (pkg.tarball.isEmpty()) throw PackageError("${pkg.name}: bad tarball URL")
            val response = session.transport(pkg.tarball, emptyMap())
            if (response.status != 200) throw PackageError("${pkg.name}: tarball download failed")
            verifyIntegrity(response.body, pkg)
            val destination = File(root, placement.path)
            destination.deleteRecursively()
            destination.mkdirs()
            TarGz.extract(response.body, into = destination, stripComponents = 1)
            if (placement.installedAs != null) {
                progress("${placement.installedAs}@${pkg.version} as ${pkg.name}")
            } else {
                progress("${pkg.name}@${pkg.version}")
            }
            if (placement.atRoot) {
                for ((bin, file) in pkg.bin) {
                    report.bins[bin] = "${placement.path}/${file.removePrefix("./")}"
                }
            }
        }
        writeManifest(report, root)
        return report
    }

    private fun verifyIntegrity(data: ByteArray, pkg: ResolvedPackage) {
        val integrity = pkg.integrity
        if (integrity != null) {
            val pieces = integrity.split("-", limit = 2)
            if (pieces.size != 2) return
            val expected = pieces[1]
            val algorithm = when (pieces[0]) {
                "sha512" -> "SHA-512"
                "sha256" -> "SHA-256"
                "sha1" -> "SHA-1"
                else -> return
            }
            val actual = Base64.getEncoder().encodeToString(MessageDigest.getInstance(algorithm).digest(data))
            if (actual != expected) throw PackageError("${pkg.name}: integrity check failed")
        } else if (pkg.shasum != null) {
            val actual = MessageDigest.getInstance("SHA-1").digest(data)
                .joinToString("") { "%02x".format(it) }
            if (actual != pkg.shasum) throw PackageError("${pkg.name}: integrity check failed")
        }
    }

    // MARK: - Manifest ($PATH's view of node_modules)

    const val MANIFEST_PATH = "node_modules/.mouse-manifest.json"

    class Manifest(val packages: MutableMap<String, String>, val bins: MutableMap<String, String>)

    fun writeManifest(report: InstallReport, root: File) {
        val existing = readManifest(root) ?: Manifest(LinkedHashMap(), LinkedHashMap())
        for (placement in report.placements) existing.packages[placement.path] = placement.pkg.version
        for ((bin, path) in report.bins) existing.bins[bin] = path
        val json = mapOf("packages" to existing.packages, "bins" to existing.bins)
        val file = File(root, MANIFEST_PATH)
        file.parentFile?.mkdirs()
        file.writeText(Json.write(json, pretty = true), Charsets.UTF_8)
    }

    fun readManifest(root: File): Manifest? {
        val file = File(root, MANIFEST_PATH)
        if (!file.isFile) return null
        val json = Json.parseObjectOrNull(runCatching { file.readText(Charsets.UTF_8) }.getOrNull() ?: return null)
            ?: return null
        return Manifest(
            LinkedHashMap(json["packages"].asStringMap()),
            LinkedHashMap(json["bins"].asStringMap()),
        )
    }

    // MARK: - package.json

    fun readPackageJSON(root: File): Map<String, Any?>? {
        val file = File(root, "package.json")
        if (!file.isFile) return null
        return Json.parseObjectOrNull(runCatching { file.readText(Charsets.UTF_8) }.getOrNull() ?: return null)
    }

    fun writePackageJSON(json: Map<String, Any?>, root: File) {
        File(root, "package.json").writeText(Json.write(json, pretty = true), Charsets.UTF_8)
    }

    // MARK: - HTTP

    /** The default transport: plain `HttpURLConnection`, no third-party client. */
    fun httpGet(url: String, headers: Map<String, String>): HttpResponse {
        // `URI(…).toURL()` rather than `URL(String)`: the latter is deprecated from JDK 20 on and
        // the module has to compile warning-free against both the JDK and the Android SDK.
        val connection = (URI(url).toURL().openConnection() as HttpURLConnection).apply {
            requestMethod = "GET"
            connectTimeout = 30_000
            readTimeout = 60_000
            for ((key, value) in headers) setRequestProperty(key, value)
        }
        return try {
            val status = connection.responseCode
            val stream = if (status in 200..299) connection.inputStream else connection.errorStream
            val body = stream?.use { it.readBytes() } ?: ByteArray(0)
            HttpResponse(status, body)
        } finally {
            connection.disconnect()
        }
    }
}
