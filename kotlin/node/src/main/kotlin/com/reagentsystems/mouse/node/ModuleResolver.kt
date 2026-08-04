package com.reagentsystems.mouse.node

import com.reagentsystems.mouse.packages.Json
import java.net.URLDecoder

/**
 * Node's module resolution algorithm, over the workspace-virtual filesystem.
 *
 * ## Why this is Kotlin and the loader is JavaScript
 *
 * `require(x)` is two jobs that look like one. RESOLUTION turns a specifier into a path — the
 * node_modules walk, `package.json` "exports"/"main"/"imports", extension probing, index files,
 * the `#name` and `file://` forms. LOADING reads that path, wraps it in the module function and
 * evaluates it, which can only happen in the JavaScript engine.
 *
 * `NodeEngine.swift` splits them the same way: `resolveModule` is Swift, and the wrapping and
 * evaluation happen through `context.evaluateScript`. So the split here is not an Android
 * compromise, it is the same line — and it puts the half with all the RULES in it somewhere a
 * JVM harness can reach, which is the whole reason `:node` exists as a module.
 *
 * The Android loader lives in `node-host.js` and asks this class one question per require, over
 * the `__mouseHost` bridge, as JSON.
 *
 * ## The two deliberate gaps
 *
 * **TypeScript `paths` aliases.** iOS tries a tsconfig alias before node_modules, by calling into
 * the bootstrap's TypeScript bridge. That needs a TypeScript compiler loaded through the very
 * loader being built, and Android has no transpiler wired yet, so an alias is not tried here.
 * A project using one gets MODULE_NOT_FOUND, which is what node itself gives.
 *
 * **ES modules.** Resolution handles them — the "import" condition is exactly what makes a dual
 * package hand each syntax its own build, and [isESModule] is here so the loader can tell. What
 * Android has no transpiler for is EVALUATING one, so the loader refuses with node's own
 * `ERR_REQUIRE_ESM`. That is the same answer real node gives for `require()` of an ES module; the
 * gap against iOS is iOS's transpiler, not a wrong answer.
 */
class ModuleResolver(private val fs: NodeFs) {

    /** What a specifier resolved to. */
    sealed class Resolution {
        data class Core(val name: String) : Resolution()
        data class File(val id: String) : Resolution()
        data class JsonFile(val id: String) : Resolution()

        /**
         * A `.node` file: compiled machine code. It RESOLVES — the file is right there — and
         * fails at load, which is where the platform's answer belongs. Reporting it as not-found
         * sent people deleting node_modules over something no reinstall can fix.
         */
        data class Addon(val id: String) : Resolution()

        data class NotFound(val message: String) : Resolution()

        /**
         * A package declared "exports" and the request is not in it. Node treats the map as the
         * package's ONLY public surface, so this is a refusal rather than a miss, and it has its
         * own code, which tools branch on.
         */
        data class NotExported(val message: String) : Resolution()
    }

    /**
     * Resolve [rawRequest] as it was written in [fromDir].
     *
     * [esm] is the syntax the REQUEST used, which is what picks the export condition: node
     * resolves `import 'x'` on "import" and `require('x')` on "require", and a dual package ships
     * genuinely different files behind the two.
     */
    fun resolve(rawRequest: String, fromDir: String, esm: Boolean = false): Resolution {
        var request = rawRequest
        if (request.startsWith("node:")) request = request.substring(5)
        if (request in CORE_MODULES) return Resolution.Core(request)

        // A `file://` URL is a legal specifier for dynamic import, and it is what a tool hands us
        // when cache-busting an ESM config (eslint appends the file's mtime as a query). Neither
        // query nor fragment is part of the filename, and the path is percent-encoded.
        if (request.lowercase().startsWith("file://")) {
            var rest = request.substring("file://".length)
            val cut = rest.indexOfFirst { it == '?' || it == '#' }
            if (cut >= 0) rest = rest.substring(0, cut)
            if (!rest.startsWith("/")) {
                // An authority, which for a file URL carries no path.
                val slash = rest.indexOf('/')
                rest = if (slash >= 0) rest.substring(slash) else "/"
            }
            request = try {
                URLDecoder.decode(rest, "UTF-8")
            } catch (_: Exception) {
                rest
            }
            return loadAsFileOrDirectory(fs.normalize(request), esm)
                ?: Resolution.NotFound("Cannot find module '$rawRequest'")
        }

        // "#name": the package.json "imports" field of the requiring package.
        if (request.startsWith("#")) {
            var dir = fromDir
            while (true) {
                val json = packageJson("$dir/package.json")
                val imports = json?.get("imports")
                if (imports is Map<*, *>) {
                    @Suppress("UNCHECKED_CAST")
                    val map = imports as Map<String, Any?>
                    val target = exportsTarget(map[request], ".", esm) ?: map[request] as? String
                    if (target != null) {
                        val found = loadAsFileOrDirectory(fs.normalize("$dir/$target"), esm)
                        if (found != null) return found
                    }
                    break
                }
                // A package.json WITHOUT "imports" is not the end of the walk: node keeps going
                // up. (NodeEngine.resolveModule breaks only on the `let imports =` binding.)
                if (dir == "/" || dir.isEmpty()) break
                dir = fs.virtualDirname(dir)
            }
            return Resolution.NotFound("Cannot find module '$rawRequest'")
        }

        // `require(".")` and `require("..")` are relative DIRECTORY requests — webpack's
        // Compiler.js requires its own package that way, and without the bare forms here they
        // fall through to the node_modules walk and fail.
        if (request == "." || request == ".." ||
            request.startsWith("./") || request.startsWith("../") || request.startsWith("/")
        ) {
            val base = if (request.startsWith("/")) request else "$fromDir/$request"
            return loadAsFileOrDirectory(fs.normalize(base), esm)
                ?: Resolution.NotFound("Cannot find module '$rawRequest'")
        }

        // Bare specifier: walk node_modules upward from the requiring directory. A bare specifier
        // with a slash is NOT a path — `rollup/parseAst` is an "exports" KEY, and a package that
        // declares "exports" publishes only what that map names. Trying the map before the
        // literal path is node's order; falling back to the path afterwards keeps packages whose
        // map is incomplete working, where node would refuse.
        val (packageName, subpath) = splitBareSpecifier(request)
        var dir = fromDir
        while (true) {
            val packageDir = fs.normalize("$dir/node_modules/$packageName")
            if (subpath != "." && isDirectory(packageDir)) {
                val json = packageJson("$packageDir/package.json")
                val exports = json?.get("exports")
                if (json != null && json.containsKey("exports")) {
                    val target = exportsTarget(exports, subpath, esm)
                    val found = target?.let { loadAsFileOrDirectory(fs.normalize("$packageDir/$it"), esm) }
                    return found ?: Resolution.NotExported(
                        "Package subpath '$subpath' is not defined by \"exports\" in " +
                            "$packageDir/package.json",
                    )
                }
            }
            val candidate = fs.normalize("$dir/node_modules/$request")
            val found = loadAsFileOrDirectory(candidate, esm)
            if (found != null) return found
            if (dir == "/" || dir.isEmpty()) break
            dir = fs.virtualDirname(dir)
        }
        return Resolution.NotFound("Cannot find module '$rawRequest'")
    }

    /**
     * `require.resolve.paths(request)`: the directories that WOULD be searched. jest asks for
     * these to build its own module registry, so a missing one stops it at startup. node returns
     * null for a core module, the node_modules walk-up for a bare specifier, and just the
     * requiring directory for a relative one.
     */
    fun resolvePaths(request: String, fromDir: String): List<String>? {
        var name = request
        if (name.startsWith("node:")) name = name.substring(5)
        if (name in CORE_MODULES) return null
        if (request.startsWith("./") || request.startsWith("../") || request == "." || request == "..") {
            return listOf(fromDir.ifEmpty { "/" })
        }
        val paths = ArrayList<String>()
        var dir = fromDir.ifEmpty { "/" }
        while (true) {
            paths.add(if (dir == "/") "/node_modules" else "$dir/node_modules")
            if (dir == "/" || dir.isEmpty()) break
            dir = fs.virtualDirname(dir)
        }
        return paths
    }

    // --------------------------------------------------------------------- the walk ----

    private fun loadAsFileOrDirectory(path: String, esm: Boolean): Resolution? {
        fun fileResolution(virtual: String): Resolution = when {
            virtual.endsWith(".json") -> Resolution.JsonFile(virtual)
            virtual.endsWith(".node") -> Resolution.Addon(virtual)
            else -> Resolution.File(virtual)
        }

        if (isFile(path)) return fileResolution(path)
        for (suffix in EXTENSIONS) {
            val candidate = path + suffix
            if (isFile(candidate)) return fileResolution(candidate)
        }
        if (!isDirectory(path)) return null

        // package.json: "exports" (string or {".": …}) wins, then "main", then index.js.
        val json = packageJson("$path/package.json")
        if (json != null) {
            // With "exports" present, node ignores "main" and "index.js" entirely: the map is the
            // whole of what the package publishes.
            if (json.containsKey("exports")) {
                val target = exportsTarget(json["exports"], ".", esm) ?: return null
                return loadAsFileOrDirectory(fs.normalize("$path/$target"), esm)
            }
            val main = json["main"] as? String
            if (!main.isNullOrEmpty()) {
                val found = loadAsFileOrDirectory(fs.normalize("$path/$main"), esm)
                if (found != null) return found
            }
        }
        for (index in listOf("/index.js", "/index.json")) {
            val candidate = path + index
            if (fs.stat(candidate, true) != null) return fileResolution(candidate)
        }
        return null
    }

    private fun isFile(path: String): Boolean {
        val info = fs.stat(path, true) ?: return false
        return info["dir"] != true
    }

    private fun isDirectory(path: String): Boolean = fs.stat(path, true)?.get("dir") == true

    private fun packageJson(path: String): Map<String, Any?>? {
        val text = fs.readText(path) ?: return null
        return Json.parseObjectOrNull(text)
    }

    // ---------------------------------------------------------------------- exports ----

    /**
     * Split a bare specifier into its package and the subpath below it: `rollup/parseAst` is the
     * package `rollup` and the exports key `./parseAst`, and a scope keeps two segments
     * (`@babel/core/lib/x` → `@babel/core`, `./lib/x`).
     */
    fun splitBareSpecifier(request: String): Pair<String, String> {
        val pieces = request.split("/").toMutableList()
        var nameCount = 1
        if (pieces.firstOrNull()?.startsWith("@") == true && pieces.size >= 2) nameCount = 2
        if (pieces.size <= nameCount) return request to "."
        val name = pieces.take(nameCount).joinToString("/")
        repeat(nameCount) { pieces.removeAt(0) }
        return name to "./" + pieces.joinToString("/")
    }

    /**
     * node's PACKAGE_EXPORTS_RESOLVE: a string, an array of fallbacks, a conditions object, or a
     * subpath map with exact keys and `*` patterns. [subpath] is "." or "./something".
     *
     * The condition SET comes from how the request was written, not from a fixed preference: an
     * `import` sees {node, import, default} and a `require` sees {node, require, default}, which
     * is what makes a dual package hand each syntax its own build.
     */
    fun exportsTarget(exports: Any?, subpath: String = ".", esm: Boolean): String? {
        val syntax = if (esm) "import" else "require"
        // Ordered most specific first, matching NodeEngine.exportsTarget: a platform condition
        // wraps a syntax condition, and "default" is written last.
        val order = listOf("node", syntax, "default")

        fun target(value: Any?, star: String?): String? {
            if (value is String) {
                if (value.isEmpty()) return null
                return if (star != null) value.replace("*", star) else value
            }
            if (value is List<*>) {
                for (item in value) {
                    val found = target(item, star)
                    if (found != null) return found
                }
                return null
            }
            // null is a BLOCKED export, not a miss.
            val map = value as? Map<*, *> ?: return null
            for (key in order) {
                val found = target(map[key], star)
                if (found != null) return found
            }
            return null
        }

        if (exports == null) return null
        // A string or an array of fallbacks is the whole export; only an object can be a SUBPATH
        // map, and only then when its keys look like subpaths ("." or "./x") rather than
        // conditions ("node", "import").
        val map = exports as? Map<*, *>
            ?: return if (subpath == ".") target(exports, null) else null
        val isSubpathMap = map.keys.any { it == "." || (it as? String)?.startsWith("./") == true }

        if (subpath == ".") return target(if (isSubpathMap) map["."] else map, null)
        if (!isSubpathMap) return null
        if (map.containsKey(subpath)) return target(map[subpath], null)

        // Pattern keys: the longest literal prefix before `*` wins, as node specifies.
        var best: Triple<String, String, Any?>? = null
        for ((rawKey, value) in map) {
            val key = rawKey as? String ?: continue
            if (!key.contains("*")) continue
            val parts = key.split("*")
            if (parts.size != 2) continue
            val (prefix, suffix) = parts[0] to parts[1]
            if (!subpath.startsWith(prefix) || !subpath.endsWith(suffix)) continue
            if (subpath.length < prefix.length + suffix.length) continue
            if (best == null || prefix.length > best!!.first.length) best = Triple(prefix, suffix, value)
        }
        val winner = best ?: return null
        val star = subpath.substring(winner.first.length, subpath.length - winner.second.length)
        return target(winner.third, star)
    }

    // -------------------------------------------------------------------------- ESM ----

    /**
     * `.mjs` is ESM, `.cjs` is CJS, `.js` follows the nearest package.json "type", and a file with
     * top-of-line import/export statements is ESM regardless (entry scripts). The same rule
     * `NodeEngine.isESModule` applies, so the two platforms classify a file identically — one of
     * them then transpiles it and the other refuses.
     */
    fun isESModule(id: String, source: String): Boolean {
        if (id.endsWith(".mjs")) return true
        if (id.endsWith(".cjs")) return false
        if (packageType(fs.virtualDirname(id)) == "module") return true
        return ESM_SYNTAX.containsMatchIn(source) && !CJS_SYNTAX.containsMatchIn(source)
    }

    /** The nearest package.json's "type", or "commonjs". */
    fun packageType(dir: String): String {
        packageTypeCache[dir]?.let { return it }
        var current = dir
        while (true) {
            val json = packageJson("$current/package.json")
            if (json != null) {
                val type = json["type"] as? String ?: "commonjs"
                packageTypeCache[dir] = type
                return type
            }
            if (current == "/" || current.isEmpty()) break
            current = fs.virtualDirname(current)
        }
        packageTypeCache[dir] = "commonjs"
        return "commonjs"
    }

    private val packageTypeCache = HashMap<String, String>()

    /** Forget every cached package "type". The loader calls this when a run begins. */
    fun clearCaches() = packageTypeCache.clear()

    // ------------------------------------------------------------------ marshalling ----

    /**
     * One require's worth of answer, as the JSON `node-host.js` reads.
     *
     * `kind` is core | file | json | addon | error, and an error carries the message the loader
     * throws and the code it throws it with — which is the point of carrying it rather than
     * letting the loader guess: `ERR_PACKAGE_PATH_NOT_EXPORTED` is a different fact from
     * `MODULE_NOT_FOUND`, and tools branch on it.
     */
    fun resolveJson(request: String, fromDir: String, esm: Boolean): String {
        val answer: Map<String, Any?> = when (val resolution = resolve(request, fromDir, esm)) {
            is Resolution.Core -> mapOf("kind" to "core", "id" to resolution.name)
            is Resolution.File -> mapOf("kind" to "file", "id" to resolution.id)
            is Resolution.JsonFile -> mapOf("kind" to "json", "id" to resolution.id)
            is Resolution.Addon -> mapOf(
                "kind" to "addon",
                "id" to resolution.id,
                // The same wall process.dlopen hits, named for THIS platform: since API 29 an app
                // targeting 29+ cannot exec or dlopen a file out of its own writable data
                // directory, which is where an installed package lives.
                "message" to "Cannot load '${resolution.id}': a .node addon is compiled machine " +
                    "code, and Android will not load one from app-private storage",
                "code" to "ERR_DLOPEN_FAILED",
            )
            is Resolution.NotFound -> mapOf(
                "kind" to "error", "message" to resolution.message, "code" to "MODULE_NOT_FOUND",
            )
            is Resolution.NotExported -> mapOf(
                "kind" to "error",
                "message" to resolution.message,
                "code" to "ERR_PACKAGE_PATH_NOT_EXPORTED",
            )
        }
        return Json.write(answer)
    }

    /** [resolvePaths] as JSON: an array, or `null` for a core module. */
    fun resolvePathsJson(request: String, fromDir: String): String =
        Json.write(resolvePaths(request, fromDir))

    /**
     * One module's SOURCE and its format, as `{"source": …, "esm": …}` — or null when the file
     * cannot be read, which the loader turns into the same MODULE_NOT_FOUND a missing file gives.
     *
     * Read and classify together, in one crossing. Handing the source over the bridge only to be
     * handed straight back for classification would double the cost for a megabyte-sized bundle,
     * and it would give the ES-module rule a second home to disagree from.
     *
     * The shebang goes first, exactly as `NodeEngine.requireModule` strips it before deciding
     * anything: an executable's `#!/usr/bin/env node` is not JavaScript, and leaving it until
     * after the format test would let a `#!` line's contents vote on the answer.
     */
    fun loadJson(id: String): String? {
        var source = fs.readText(id) ?: return null
        if (source.startsWith("#!")) {
            val newline = source.indexOf('\n')
            source = if (newline < 0) "" else source.substring(newline)
        }
        val esm = isESModule(id, source)
        // The transpile happens HERE, not in the loader, for the reason the loader's own note
        // gives: only the engine can run a module, but only the host can rewrite one. iOS draws
        // the same line — `transpileESM` is Swift and the loader receives CommonJS.
        //
        // Dynamic `import(` is rewritten in CommonJS too, because it is legal there and no
        // engine here has a module loader wired to this resolver. prettier lazy-loads its
        // plugins that way.
        val body = if (esm) EsmTranspiler.transpile(source) else EsmTranspiler.rewriteDynamicImport(source)
        // `async` is NOT the same question as `esm`, and conflating them was the jose bug. Only a
        // module with top-level await has to be evaluated asynchronously; every other ES module
        // finishes when its body returns, so `require()` of it can answer the real namespace the
        // way node 22 does. See `EsmTranspiler.hasTopLevelAwait`.
        val async = esm && EsmTranspiler.hasTopLevelAwait(source)
        return Json.write(mapOf("source" to body, "esm" to esm, "async" to async))
    }

    companion object {
        /** The core module names the engine answers. Identical to `NodeEngine.coreModules`. */
        val CORE_MODULES: Set<String> = linkedSetOf(
            "fs", "path", "os", "util", "events", "buffer", "tty", "assert", "url",
            "child_process", "http", "https", "net", "crypto", "stream", "zlib",
            "readline", "readline/promises", "string_decoder", "constants", "querystring",
            "fs/promises", "stream/promises", "process", "module", "timers", "timers/promises",
            "path/posix", "path/win32", "http2", "tls", "dns", "worker_threads", "async_hooks",
            "v8", "vm", "perf_hooks", "inspector", "dgram", "cluster", "diagnostics_channel",
            "console", "util/types", "domain", "wasi",
        )

        /** Probed in order after the literal path, exactly as `loadAsFileOrDirectory` does. */
        val EXTENSIONS: List<String> =
            listOf(".js", ".cjs", ".json", ".node", ".ts", ".tsx", ".mts", ".cts")

        private val ESM_SYNTAX = Regex(
            """(?m)^\s*(import\s+[\w{*'"]|import\s*\(|export\s+(default|const|let|var|function|class|\{|\*))""",
        )
        private val CJS_SYNTAX = Regex("""(?m)^\s*(module\.exports|exports\.)""")
    }
}
