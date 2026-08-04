package com.reagentsystems.mouse.pkgcheck

import com.reagentsystems.mouse.packages.Json
import com.reagentsystems.mouse.packages.PackageManager
import com.reagentsystems.mouse.packages.RuntimeCatalog
import com.reagentsystems.mouse.packages.RuntimeStore
import com.reagentsystems.mouse.packages.Semver
import com.reagentsystems.mouse.packages.SemverRange
import com.reagentsystems.mouse.packages.TarGz
import com.reagentsystems.mouse.packages.asObject
import com.reagentsystems.mouse.packages.ZipArchive
import com.reagentsystems.mouse.packages.asString
import com.reagentsystems.mouse.packages.asStringMap
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.TimeUnit
import java.util.zip.Deflater
import kotlin.system.exitProcess

// Headless verification of the Kotlin PackageManager — semver, npm registry resolution,
// integrity, the install tree, npm: aliases, the wasm substitutions, and TarGz.
//
// The corpus is the iOS one, ported assertion for assertion, because a parity claim that is
// gated differently on the two platforms is unfalsifiable (plans/android-parity.md):
//
//   verify/pkg/       — the semver corpus, resolveTree vs real `pnpm install --lockfile-only`,
//                       and install() proven by real `node` requiring out of the tree
//   verify/npmalias/  — `npm:real-name@range` installs under the requested name, side by side
//                       with a different major of the same package
//   verify/napiwasi/  — the `…-wasm32-wasi` optional dependency is the one that gets installed
//                       (the resolution half; the loader half needs phase G)
//
// It hits the REAL registry and runs the REAL pnpm and node, exactly as the Swift harnesses do:
// a mocked registry grades the mock. Tarballs are content-addressed and immutable, so they are
// cached under ~/.cache/mouse-verify like verify/python's runtime; PACKUMENTS deliberately are
// not, because they change when someone publishes and a cached one would lose a publish race
// against the live pnpm this is graded against.
//
// No JUnit, by invariant #4: this is a main() that prints one verdict line and exits non-zero,
// the same shape as the Swift harnesses in verify/ and as :screencheck.

private var failures = 0
private var checks = 0

private fun check(condition: Boolean, label: String) {
    checks += 1
    if (!condition) {
        failures += 1
        println("  FAIL: $label")
    }
}

private fun fail(label: String) {
    checks += 1
    failures += 1
    println("  FAIL: $label")
}

// ------------------------------------------------------------------ tools on this machine ----

private fun findTool(name: String, vararg extra: String): File? {
    for (path in extra) {
        val file = File(path)
        if (file.canExecute()) return file
    }
    val home = System.getProperty("user.home")
    val candidates = (System.getenv("PATH") ?: "").split(":") + listOf("$home/.local/bin", "/usr/local/bin", "/opt/homebrew/bin")
    for (dir in candidates) {
        if (dir.isEmpty()) continue
        val file = File(dir, name)
        if (file.canExecute()) return file
    }
    return null
}

private class Ran(val status: Int, val out: String, val err: String)

private fun run(exe: File, args: List<String>, cwd: File? = null, env: Map<String, String> = emptyMap()): Ran {
    val builder = ProcessBuilder(listOf(exe.absolutePath) + args)
    if (cwd != null) builder.directory(cwd)
    builder.environment().putAll(env)
    val process = builder.start()
    // Both pipes drain concurrently: pnpm fills its 64 KB stderr buffer while we are still
    // reading stdout, and a sequential read deadlocks there.
    var err = ""
    val drain = Thread { err = process.errorStream.bufferedReader().readText() }
    drain.start()
    val out = process.inputStream.bufferedReader().readText()
    drain.join()
    process.waitFor(10, TimeUnit.MINUTES)
    return Ran(process.exitValue(), out, err)
}

// --------------------------------------------------------------------- the caching transport --

private val tarballCache = File(System.getProperty("user.home"), ".cache/mouse-verify/npm-tarballs")

/**
 * The default transport, with immutable tarballs served from disk on a rerun. A packument goes
 * to the network every time — see the note at the top of the file.
 */
private fun cachingTransport(url: String, headers: Map<String, String>): PackageManager.HttpResponse {
    if (!url.endsWith(".tgz") && !url.endsWith(".tar.gz")) {
        return PackageManager.httpGet(url, headers)
    }
    val key = MessageDigest.getInstance("SHA-256").digest(url.toByteArray()).joinToString("") { "%02x".format(it) }
    val file = File(tarballCache, "$key.tgz")
    if (file.isFile) return PackageManager.HttpResponse(200, file.readBytes())
    val response = PackageManager.httpGet(url, headers)
    if (response.status == 200) {
        tarballCache.mkdirs()
        file.writeBytes(response.body)
    }
    return response
}

private fun session() = PackageManager.Session(transport = ::cachingTransport)

// ------------------------------------------------------------------------ 1. semver corpus ----

private fun satisfies(version: String, range: String): Boolean {
    val v = Semver.parse(version) ?: return false
    val r = SemverRange.parse(range) ?: return false
    return r.satisfiedBy(v)
}

private fun semverCorpus() {
    // Ported line for line from verify/pkg/main.swift's first section.
    check(satisfies("2.1.2", ">= 2.1.2 < 3.0.0"), "space-after-operator range (safer-buffer)")
    check(satisfies("2.9.9", ">= 2.1.2 < 3.0.0"), "space range upper interior")
    check(!satisfies("3.0.0", ">= 2.1.2 < 3.0.0"), "space range upper bound")
    check(!satisfies("2.1.1", ">= 2.1.2 < 3.0.0"), "space range lower bound")
    check(satisfies("1.2.3", "^1.2.3"), "^ basic")
    check(satisfies("1.9.9", "^1.2.3"), "^ minor drift")
    check(!satisfies("2.0.0", "^1.2.3"), "^ major bound")
    check(satisfies("0.2.5", "^0.2.3"), "^0.x patch drift")
    check(!satisfies("0.3.0", "^0.2.3"), "^0.x minor bound")
    check(!satisfies("0.0.4", "^0.0.3"), "^0.0.x exact")
    check(satisfies("1.2.9", "~1.2.3"), "~ patch drift")
    check(!satisfies("1.3.0", "~1.2.3"), "~ minor bound")
    check(satisfies("1.9.0", "~1"), "~ major-only")
    check(satisfies("1.2.3", ">=1.0.0 <2.0.0"), "and-set")
    check(satisfies("3.1.0", "^1.0.0 || ^3.0.0"), "or-set")
    check(!satisfies("2.5.0", "^1.0.0 || ^3.0.0"), "or-set gap")
    check(satisfies("1.5.0", "1.x"), "x-range")
    check(!satisfies("2.0.0", "1.x"), "x-range bound")
    check(satisfies("1.2.0", "1.2"), "partial as x-range")
    check(satisfies("5.0.0", "*"), "star")
    check(satisfies("1.2.3", "1.2.3"), "exact")
    check(!satisfies("1.2.4", "1.2.3"), "exact miss")
    check(satisfies("1.5.0", "1.2.3 - 2.0.0"), "hyphen")
    check(!satisfies("2.0.1", "1.2.3 - 2.0.0"), "hyphen upper")
    check(satisfies("2.0.0", ">=2.0.0-0"), "prerelease anchor allows release")
    check(!satisfies("2.0.0-beta.1", "^1.0.0"), "prerelease hidden from plain range")
    check(satisfies("2.0.0-beta.2", ">=2.0.0-beta.1"), "prerelease with anchor")
    check(satisfies("1.2.3", ">1.2.2"), "gt")
    check(satisfies("1.3.0", ">1.2"), "gt partial bumps")
    check(!satisfies("1.2.9", ">1.2"), "gt partial excludes the partial itself")

    val v = { text: String -> Semver.parse(text)!! }
    check(v("1.2.3-alpha") < v("1.2.3"), "prerelease < release")
    check(v("1.2.3-alpha.2") < v("1.2.3-alpha.10"), "numeric prerelease compare")

    // The rest of semver §11's precedence chain, which the Swift comparator implements and the
    // Swift harness only samples. Every neighbouring pair in this list must be strictly ordered.
    val chain = listOf(
        "1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta",
        "1.0.0-beta.2", "1.0.0-beta.11", "1.0.0-rc.1", "1.0.0",
        "1.0.1", "1.1.0", "2.0.0",
    )
    for (i in 0 until chain.size - 1) {
        check(v(chain[i]) < v(chain[i + 1]), "precedence ${chain[i]} < ${chain[i + 1]}")
    }
    check(v("1.0.0+build.1") == v("1.0.0"), "build metadata does not affect precedence")
    check(v("1.0.0-alpha") < v("1.0.0-alpha.1"), "a shorter prerelease set is lower")
    check(Semver.parse("1.2") == null, "a two-part version is not a Semver")
    check(Semver.parse("1.2.x") == null, "an x-range is not a Semver")
    check(v("v1.2.3") == v("1.2.3"), "a leading v is accepted")

    // Ranges the resolver meets in real packuments.
    check(satisfies("4.1.2", "^4.0.0 || ^5.0.0"), "or-set with two carets")
    check(satisfies("1.0.0", ">=1.0.0 <2.0.0-0"), "prerelease-excluding upper bound")
    check(!satisfies("2.0.0-rc.1", ">=1.0.0 <2.0.0-0"), "…still hides 2.0.0-rc.1")
    check(satisfies("7.2.3", "7.x"), "x-range with a real major")
    check(satisfies("0.0.3", "^0.0.3"), "^0.0.x matches itself")
    check(satisfies("1.2.3", ""), "an empty range is *")
    check(SemverRange.parse("not-a-range") == null, "garbage does not parse as a range")
}

// ------------------------------------------------------------------- 2. TarGz, gzip, JSON -----

private fun tarCorpus(scratch: File) {
    val tar = findTool("tar", "/usr/bin/tar")
    if (tar == null) { fail("no tar on this machine to build a fixture archive with"); return }

    // A real archive, written by a real tar: a nested tree, a path long enough to force the
    // pax/GNU long-name record, and a symlink.
    val source = File(scratch, "tar-src/top")
    val deepName = "d".repeat(120)
    File(source, "lib/nested").mkdirs()
    File(source, "lib/nested/one.txt").writeText("first")
    File(source, "lib/$deepName.txt").writeText("long path")
    run(tar, listOf("-czf", File(scratch, "fixture.tgz").absolutePath, "-C", File(scratch, "tar-src").absolutePath, "top"))

    val out = File(scratch, "tar-out")
    out.mkdirs()
    TarGz.extract(File(scratch, "fixture.tgz").readBytes(), into = out, stripComponents = 1)
    check(File(out, "lib/nested/one.txt").readText() == "first", "tar: nested file round-trips")
    check(File(out, "lib/$deepName.txt").readText() == "long path", "tar: a 120-char name survives (pax/GNU path record)")
    check(!File(out, "top").exists(), "tar: stripComponents removed the top folder")

    // gzip framing and raw DEFLATE, the two entry points ZipArchive will want in phase 4.
    val payload = ("mouse " + "x".repeat(5000)).toByteArray()
    val deflater = Deflater(Deflater.BEST_COMPRESSION, true)
    deflater.setInput(payload)
    deflater.finish()
    val compressed = java.io.ByteArrayOutputStream()
    val chunk = ByteArray(4096)
    while (!deflater.finished()) compressed.write(chunk, 0, deflater.deflate(chunk))
    deflater.end()
    check(TarGz.inflateRaw(compressed.toByteArray()).contentEquals(payload), "inflateRaw round-trips a raw DEFLATE stream")

    var refused = false
    try { TarGz.gunzip("not a gzip".toByteArray()) } catch (e: TarGz.ExtractError) { refused = true }
    check(refused, "gunzip refuses something that is not gzip")

    // The JSON reader/writer this module had to bring its own of.
    // A raw Kotlin string, so the backslashes below reach the JSON reader as JSON escapes.
    val document = """
        {"name":"probe","version":"1.0.0","deps":{"b":"^1.0.0","a":"~2"},
         "list":[1,2.5,true,false,null,"tab\there"],"escaped":"\u00e9\u4e2d\ud83d\udc0d","big":12345678901}
    """.trimIndent()
    val parsed = Json.parse(document).asObject()
    if (parsed == null) {
        fail("JSON: the document did not parse as an object")
    } else {
        check(parsed["name"].asString() == "probe", "JSON: string value")
        check(parsed["escaped"].asString() == "é中🐍", "JSON: \\u escapes decode, surrogate pair included")
        check((parsed["list"] as List<*>)[5] == "tab\there", "JSON: escapes inside an array")
        check(parsed["big"] == 12345678901L, "JSON: an integer past Int stays exact")
        val written = Json.write(parsed, pretty = true)
        check(written.indexOf("\"a\"") < written.indexOf("\"b\""), "JSON: keys are written sorted")
        check(Json.write(Json.parse(written)) == Json.write(parsed), "JSON: write/parse round-trips")
    }
}

// ------------------------------------------------------- 3. resolveTree vs real pnpm ----------

private fun pnpmResolve(pnpm: File, name: String, requirement: String, scratch: File): Set<String> {
    val dir = File(scratch, "pnpm-${name.replace("/", "_")}")
    dir.mkdirs()
    File(dir, "package.json").writeText(
        Json.write(mapOf("name" to "probe", "version" to "1.0.0", "dependencies" to mapOf(name to requirement))),
    )
    // pnpm 11's default minimumReleaseAge (supply-chain gate) skips versions published <24h ago;
    // our resolver does pure semver. Disable it so the comparison tests RESOLUTION, not
    // release-age policy (which lost the iOS side a publish race mid-session).
    //
    // Fresh metadata cache per run, for the same reason: a stale pnpm cache loses publish races
    // against our live-registry resolver. XDG dirs point pnpm's cache into the scratch area.
    val ran = run(
        pnpm,
        listOf("install", "--lockfile-only", "--ignore-scripts", "--config.minimum-release-age=0"),
        cwd = dir,
        env = mapOf(
            "XDG_CACHE_HOME" to File(dir, "xdg-cache").absolutePath,
            "XDG_DATA_HOME" to File(dir, "xdg-data").absolutePath,
            "XDG_STATE_HOME" to File(dir, "xdg-state").absolutePath,
        ),
    )
    val lock = File(dir, "pnpm-lock.yaml")
    if (!lock.isFile) {
        println("    pnpm produced no lockfile for $name (exit ${ran.status}): ${ran.err.take(200)}")
        return emptySet()
    }
    val results = HashSet<String>()
    var inPackages = false
    for (line in lock.readText().split("\n")) {
        if (line == "packages:") { inPackages = true; continue }
        if (!inPackages) continue
        if (!line.startsWith(" ") && line.isNotEmpty()) { inPackages = false; continue }
        val trimmed = line.trim()
        if (trimmed.endsWith(":") && trimmed.contains("@") && !trimmed.startsWith("resolution")) {
            results.add(trimmed.dropLast(1).trim('\'', '"'))
        }
    }
    return results
}

private fun resolutionCorpus(scratch: File) {
    val cases = listOf(
        "left-pad" to "^1.3.0",
        "mkdirp" to "^1.0.0",
        "debug" to "^4.0.0",
        "chalk" to "4.1.2",
        "glob" to "^7.2.0",
    )
    val pnpm = findTool("pnpm", "/usr/local/bin/pnpm")
    if (pnpm == null) {
        fail("no pnpm on this machine — resolution cannot be graded against a real package manager")
        return
    }
    for ((name, requirement) in cases) {
        try {
            val placements = PackageManager.resolveTree(mapOf(name to requirement), session())
            val ours = placements.map { "${it.pkg.name}@${it.pkg.version}" }.toSet()
            val theirs = pnpmResolve(pnpm, name, requirement, scratch)
            checks += 1
            if (ours != theirs) {
                failures += 1
                println("  FAIL: resolution $name: ours=${ours.sorted()} pnpm=${theirs.sorted()}")
            } else {
                println("  resolution $name: ${ours.size} packages match pnpm")
            }
        } catch (e: Exception) {
            fail("resolution $name: ${e.message}")
        }
    }
}

// ------------------------------------------------- 4. a real install, proven by real node -----

private fun installCorpus(scratch: File, node: File?) {
    val chalkRoot = File(scratch, "install-chalk")
    chalkRoot.mkdirs()
    try {
        val report = PackageManager.install(mapOf("chalk" to "4.1.2"), into = chalkRoot, session = session())
        check(
            report.placements.any { it.pkg.name == "chalk" && it.pkg.version == "4.1.2" },
            "chalk placed",
        )
        for (placement in report.placements) {
            val json = Json.parseObjectOrNull(File(chalkRoot, "${placement.path}/package.json").let {
                if (it.isFile) it.readText() else ""
            })
            if (json == null) { fail("missing package.json at ${placement.path}"); continue }
            check(json["version"].asString() == placement.pkg.version, "version on disk ${placement.path}")
        }

        // The layout is correct only if Node's own resolver agrees — the iOS gate's third leg.
        if (node == null) {
            fail("no node on this machine — the installed layout cannot be proven")
        } else {
            val ran = run(
                node,
                listOf("-e", "const c = require('chalk'); if (typeof c.red !== 'function') process.exit(1); console.log(c.level >= 0 ? 'chalk-loads' : 'x')"),
                cwd = chalkRoot,
            )
            check(ran.status == 0 && ran.out.contains("chalk-loads"), "real node requires chalk from our tree")
        }

        val manifest = PackageManager.readManifest(chalkRoot)
        check(
            manifest != null && manifest.packages.size == report.placements.size,
            "manifest records placements",
        )
    } catch (e: Exception) {
        fail("install: ${e.message}")
    }

    // glob@7: a deeper tree, with a nested placement in it; real node must resolve it too.
    val globRoot = File(scratch, "install-glob")
    globRoot.mkdirs()
    try {
        PackageManager.install(mapOf("glob" to "^7.2.0"), into = globRoot, session = session())
        if (node != null) {
            val ran = run(
                node,
                listOf("-e", "const g = require('glob'); if (typeof g.sync !== 'function') process.exit(1); console.log('glob-loads')"),
                cwd = globRoot,
            )
            check(ran.status == 0 && ran.out.contains("glob-loads"), "real node requires glob from our tree")
        }
    } catch (e: Exception) {
        fail("glob install: ${e.message}")
    }

    // mkdirp has a bin — verify bin capture end to end.
    val binRoot = File(scratch, "install-mkdirp")
    binRoot.mkdirs()
    try {
        val report = PackageManager.install(mapOf("mkdirp" to "^1.0.0"), into = binRoot, session = session())
        check(report.bins["mkdirp"] != null, "mkdirp bin recorded")
        report.bins["mkdirp"]?.let { check(File(binRoot, it).isFile, "bin file exists") }
    } catch (e: Exception) {
        fail("mkdirp install: ${e.message}")
    }
}

// ------------------------------------------------------------------------ 5. npm aliases ------

private fun aliasCorpus(scratch: File) {
    // An npm ALIAS — `"local-name": "npm:real-name@range"` — installs one published package under
    // a different directory name. It is how a tree depends on two major versions of the same
    // package at once, and it is not exotic: n8n's tree uses one, and `npx n8n` failed on the iOS
    // engine with "package not found: zod-from-json-schema-v3", a name nobody ever published,
    // because the alias was carried to the registry as if it were the package.
    val root = File(scratch, "alias")
    root.mkdirs()
    try {
        val report = PackageManager.install(
            mapOf(
                "string-width-cjs" to "npm:string-width@^4.2.3",
                "string-width" to "^5.1.2",
            ),
            into = root,
            session = session(),
        )
        // Placed under the ALIAS name…
        val aliasJson = Json.parseObjectOrNull(
            File(root, "node_modules/string-width-cjs/package.json").let { if (it.isFile) it.readText() else "" },
        )
        if (aliasJson == null) {
            fail("no node_modules/string-width-cjs/package.json — the alias never installed")
        } else {
            // …carrying the REAL package's identity inside.
            check(aliasJson["name"].asString() == "string-width", "the alias directory holds string-width")
            check(aliasJson["version"].asString()?.startsWith("4.") == true, "the alias resolved to 4.x")
        }
        // And the un-aliased dependency on the same package is a SEPARATE install at its own
        // version: resolving the alias to the same slot would silently give one the wrong major.
        val plainJson = Json.parseObjectOrNull(
            File(root, "node_modules/string-width/package.json").let { if (it.isFile) it.readText() else "" },
        )
        check(plainJson?.get("version").asString()?.startsWith("5.") == true, "string-width itself stays 5.x")
        // The install report should say what it did rather than pretend the alias was its own.
        check(
            report.placements.any { it.installedAs == "string-width-cjs" && it.pkg.name == "string-width" },
            "the report records string-width-cjs as an alias of string-width",
        )
    } catch (e: Exception) {
        fail("alias install: ${e.message}")
    }
}

// ------------------------------------------------- 6. the wasm/wasi substitutions --------------

private fun substitutionCorpus() {
    // A native package resolved under its substitute's name and PLACED under the original's, so
    // the dependent never learns the difference.
    try {
        val placements = PackageManager.resolveTree(mapOf("rollup" to "^4.0.0"), session())
        val rollup = placements.firstOrNull { it.path == "node_modules/rollup" }
        if (rollup == null) {
            fail("rollup: nothing was placed at node_modules/rollup")
        } else {
            check(rollup.pkg.name == "@rollup/wasm-node", "rollup resolves to @rollup/wasm-node")
            check(rollup.installedAs == "rollup", "…and records that it stands in for rollup")
        }
    } catch (e: Exception) {
        fail("rollup substitution: ${e.message}")
    }

    // napi-rs's shape: every platform's binary sits in optionalDependencies and only the
    // `…-wasm32-wasi` one is portable, so that is the one the tree must pull in.
    //
    // The rule is asserted on a SYNTHETIC package first, because WHICH real packages publish a
    // wasm32-wasi build is a fact about other people's release process and it moves: rolldown —
    // the package verify/napiwasi picks on iOS — dropped its wasm32-wasi binding at 1.2.x, and a
    // gate that only knew about rolldown would read as our bug when it is their choice.
    val natives = mapOf(
        "@probe/binding-darwin-arm64" to "1.0.0",
        "@probe/binding-linux-x64-gnu" to "1.0.0",
        "@probe/binding-win32-x64-msvc" to "1.0.0",
    )
    fun probe(optional: Map<String, String>) = PackageManager.ResolvedPackage(
        name = "probe", version = "1.0.0", tarball = "", integrity = null, shasum = null,
        dependencies = emptyMap(), optionalDependencies = optional, bin = emptyMap(),
    )
    check(
        PackageManager.wasiBinding(probe(natives + ("@probe/binding-wasm32-wasi" to "1.0.0")))?.first
            == "@probe/binding-wasm32-wasi",
        "wasiBinding picks the wasm32-wasi build out of a napi-rs optionalDependencies set",
    )
    check(
        PackageManager.wasiBinding(probe(natives)) == null,
        "…and answers null when a package publishes only native bindings",
    )

    // Then the same rule against the live registry, on a package that does publish one today.
    try {
        val session = session()
        val name = "unrs-resolver"
        val requirement = "^1.12.0"
        val binding = PackageManager.wasiBinding(session.resolve(name, requirement))
        if (binding == null) {
            fail("$name publishes no -wasm32-wasi optional dependency any more — their release choice, not a resolver fault; repoint this leg")
        } else {
            val placements = PackageManager.resolveTree(mapOf(name to requirement), session)
            check(placements.any { it.pkg.name == binding.first }, "the resolved tree contains ${binding.first}")
            check(
                placements.none {
                    it.pkg.name.contains("-darwin-") || it.pkg.name.contains("-linux-") ||
                        it.pkg.name.contains("-win32-")
                },
                "and none of the native per-platform bindings",
            )
        }
    } catch (e: Exception) {
        fail("unrs-resolver wasi binding: ${e.message}")
    }
}

// ------------------------------------------------------------------------- 7. integrity -------

private fun integrityCorpus(scratch: File) {
    // The integrity check has to BITE, not just exist. Same install, one byte of the tarball
    // flipped in transit: it must refuse before a byte is unpacked.
    val root = File(scratch, "integrity")
    root.mkdirs()
    val corrupting = PackageManager.Session(transport = { url, headers ->
        val response = cachingTransport(url, headers)
        if (url.endsWith(".tgz") && response.body.size > 600) {
            val body = response.body.copyOf()
            body[500] = (body[500] + 1).toByte()
            PackageManager.HttpResponse(response.status, body)
        } else {
            response
        }
    })
    var message: String? = null
    try {
        PackageManager.install(mapOf("left-pad" to "^1.3.0"), into = root, session = corrupting)
    } catch (e: PackageManager.PackageError) {
        message = e.message
    } catch (e: Exception) {
        message = "wrong error type: ${e::class.java.simpleName}: ${e.message}"
    }
    check(message == "left-pad: integrity check failed", "a corrupted tarball is refused (got: $message)")
    check(!File(root, "node_modules/left-pad/package.json").exists(), "…and nothing was unpacked")
}

// ------------------------------------------------------- 8. the runtime store (milestone 4) ---

/**
 * The catalog is read from `swift/Runtimes.json` — the SAME file the iOS app bundles, not a copy.
 * The whole "a language is data" claim rests on there being exactly one of these in the repo, and
 * a second copy under kotlin/ would let the platforms drift apart at the only layer that is
 * supposed to be shared verbatim.
 */
private val repoRoot: File by lazy {
    System.getProperty("mouse.repo.root")?.let { return@lazy File(it) }
    var candidate: File? = File(".").absoluteFile
    while (candidate != null) {
        if (File(candidate, "swift/Runtimes.json").isFile) return@lazy candidate
        candidate = candidate.parentFile
    }
    File(".").absoluteFile
}

/** Build a real zip with the system `zip`, so the reader is graded against a real writer. */
private fun makeZip(scratch: File, name: String, files: Map<String, ByteArray>): ByteArray? {
    val zipTool = findTool("zip") ?: return null
    val staging = File(scratch, "zipsrc-$name")
    staging.deleteRecursively()
    staging.mkdirs()
    for ((path, bytes) in files) {
        val target = File(staging, path)
        target.parentFile?.mkdirs()
        target.writeBytes(bytes)
    }
    val archive = File(scratch, "$name.zip")
    archive.delete()
    val ran = run(zipTool, listOf("-r", "-q", archive.absolutePath, "."), cwd = staging)
    if (ran.status != 0 || !archive.isFile) return null
    return archive.readBytes()
}

private fun runtimeCorpus(scratch: File) {
    // -- the catalog parses, and says what iOS says --------------------------------------
    val catalogFile = File(repoRoot, "swift/Runtimes.json")
    if (!catalogFile.isFile) {
        fail("swift/Runtimes.json not found at ${catalogFile.path}")
        return
    }
    val entries = try {
        RuntimeCatalog.parse(catalogFile.readText())
    } catch (e: Exception) {
        fail("the shared catalog does not parse: ${e.message}")
        return
    }
    check(entries.size >= 2, "the catalog carries more than one runtime (got ${entries.size})")
    val python = RuntimeCatalog.entry(entries, "python")
    if (python == null) {
        fail("the catalog has no python entry")
        return
    }
    check(python.archive == RuntimeCatalog.Archive.ZIP, "python is published as a zip")
    check(python.commands == listOf("python", "python3"), "python answers to python and python3")
    check(python.wasm == "python.wasm", "python's interpreter is python.wasm")
    check(python.rewriteScriptPaths, "python needs bare script paths rewritten (WASI has no cwd)")
    check(
        python.env["PYTHONHOME"] == "{root}",
        "PYTHONHOME is the {root} placeholder, not a baked path",
    )
    check(python.sha256.length == 64, "python's recorded hash is a full SHA-256")
    check(python.downloadBytes > 1_000_000, "python's recorded size is a real download size")
    val ruby = RuntimeCatalog.entry(entries, "ruby")
    check(ruby?.archive == RuntimeCatalog.Archive.TAR_GZ, "ruby is published as a tar.gz")
    check(ruby?.strip == 3, "ruby's tarball wraps its content three directories deep")
    check(
        RuntimeCatalog.forCommand(entries, "python3")?.name == "python",
        "a typed command resolves to its runtime, installed or not",
    )
    check(
        RuntimeCatalog.forCommand(entries, "perl") == null,
        "a command no runtime claims resolves to nothing",
    )

    // -- the zip reader agrees with the system unzip -------------------------------------
    // Two entries, one of them incompressible random bytes so `zip` stores it rather than
    // deflating: the reader has to handle method 0 and method 8, and a corpus of only text would
    // never produce a stored entry.
    val random = ByteArray(4096).also { java.util.Random(7).nextBytes(it) }
    val text = ("mouse ".repeat(2000)).toByteArray()
    val payload = mapOf(
        "python.wasm" to text,
        "lib/python3.14/os.py" to "import sys\n".toByteArray(),
        "lib/random.bin" to random,
    )
    val zipped = makeZip(scratch, "runtime", payload)
    if (zipped == null) {
        fail("could not build a zip with the system `zip` — the reader is ungraded")
    } else {
        val out = File(scratch, "unzipped")
        out.mkdirs()
        var failure: String? = null
        try {
            ZipArchive.extract(zipped, out)
        } catch (e: Exception) {
            failure = e.message
        }
        check(failure == null, "the zip reader unpacks a real zip (error: $failure)")
        for ((path, bytes) in payload) {
            val got = File(out, path)
            check(got.isFile, "zip reader wrote $path")
            check(got.isFile && got.readBytes().contentEquals(bytes), "zip reader round-trips $path byte for byte")
        }
        // Deflated and stored entries both appeared, or the corpus did not exercise both paths.
        check(
            String(zipped, Charsets.ISO_8859_1).contains("random.bin"),
            "the corpus zip contains the incompressible entry",
        )
    }

    // -- an entry that escapes its directory is refused ----------------------------------
    // Hand-built rather than produced by `zip`, which refuses to write one. The substitute name
    // is EXACTLY as long as the original: a zip's central directory and local headers are a web
    // of absolute offsets, and a rename that changes length corrupts the archive — which the
    // reader then rejects as malformed, passing this check for entirely the wrong reason.
    val escaping = makeZip(scratch, "escape", mapOf("inner.txt" to "x".toByteArray()))
    if (escaping != null) {
        val renamed = String(escaping, Charsets.ISO_8859_1).replace("inner.txt", "../aa.txt")
            .toByteArray(Charsets.ISO_8859_1)
        var message: String? = null
        try {
            ZipArchive.extract(renamed, File(scratch, "escaped").apply { mkdirs() })
        } catch (e: Exception) {
            message = e.message
        }
        check(
            message?.contains("escapes its directory") == true,
            "a zip entry naming .. is refused (got: $message)",
        )
    }

    // -- install, list, remove, with the download injected -------------------------------
    // The archive is real and so is every step after it; only the network is substituted, so the
    // gate does not pull 14 MB on every run. The REAL download is proven separately below.
    val store = RuntimeStore(File(scratch, "store"))
    val archive = makeZip(scratch, "install", payload)
    if (archive != null) {
        val digest = MessageDigest.getInstance("SHA-256").digest(archive).joinToString("") { "%02x".format(it) }
        val entry = python.copy(sha256 = digest, downloadBytes = archive.size.toLong())
        check(store.installed(entry) == null, "a runtime that was never installed reports absent")
        val notes = ArrayList<String>()
        var error: String? = null
        try {
            store.install(entry, note = { notes.add(it) }, fetch = { archive })
        } catch (e: Exception) {
            error = e.message
        }
        check(error == null, "a verified archive installs (error: $error)")
        check(notes.size == 2 && notes.last().startsWith("installed python"), "the install reports progress")
        val installed = store.installed(entry)
        check(installed != null, "an installed runtime is found")
        check(
            installed?.wasm?.path?.endsWith("MouseRuntimes/usr/lib/python/python.wasm") == true,
            "the layout is usr/lib/<name> so every ancestor a realpath walks is a real directory",
        )
        check(installed?.library?.isDirectory == true, "the standard library landed where the entry says")
        check(store.installedNames(listOf(entry)) == listOf("python"), "installedNames lists it")

        // A bad hash is refused, and BOTH hashes are named.
        val wrong = entry.copy(name = "wrongpy", sha256 = "0".repeat(64))
        var integrity: String? = null
        try {
            store.install(wrong, fetch = { archive })
        } catch (e: Exception) {
            integrity = e.message
        }
        check(
            integrity?.contains("does not match its recorded hash") == true &&
                integrity.contains(digest),
            "a substituted archive is refused, naming both hashes (got: $integrity)",
        )
        check(!File(store.root, "wrongpy").exists(), "…and nothing was unpacked")

        // An archive without the declared interpreter is refused, and leaves no staging behind.
        val hollowBytes = makeZip(scratch, "hollow", mapOf("readme.txt" to "nothing here".toByteArray()))
        if (hollowBytes != null) {
            val hollowDigest = MessageDigest.getInstance("SHA-256").digest(hollowBytes)
                .joinToString("") { "%02x".format(it) }
            val hollow = entry.copy(name = "hollowpy", sha256 = hollowDigest)
            var missing: String? = null
            try {
                store.install(hollow, fetch = { hollowBytes })
            } catch (e: Exception) {
                missing = e.message
            }
            check(
                missing?.contains("did not contain python.wasm") == true,
                "an archive missing its interpreter is refused (got: $missing)",
            )
            check(
                !File(store.root, ".hollowpy.incoming").exists(),
                "…and the staging directory is cleaned up",
            )
        }

        // A failed reinstall leaves the working runtime in place — the reason for staging.
        var reinstall: String? = null
        try {
            store.install(entry.copy(sha256 = "1".repeat(64)), fetch = { archive })
        } catch (e: Exception) {
            reinstall = e.message
        }
        check(reinstall != null, "a failing reinstall throws")
        check(store.installed(entry) != null, "…and the previously installed runtime survives it")

        check(store.remove(entry), "remove reports that it removed something")
        check(store.installed(entry) == null, "…and the runtime is gone")
        check(!store.remove(entry), "removing what is not there reports false")
    }

    // -- the recorded URL and hash are real ----------------------------------------------
    // This is the check that makes the catalog trustworthy rather than plausible: it downloads the
    // artifact the entry names and hashes it. Cached like the npm tarballs, since a release asset
    // is immutable.
    val cache = File(System.getProperty("user.home"), ".cache/mouse-verify/runtimes")
    val key = MessageDigest.getInstance("SHA-256").digest(python.url.toByteArray())
        .joinToString("") { "%02x".format(it) }
    val cached = File(cache, "$key.bin")
    val realStore = RuntimeStore(File(scratch, "realstore"))
    var realNotes = 0
    var realError: String? = null
    try {
        realStore.install(
            python,
            note = { realNotes += 1 },
            fetch = { url ->
                if (cached.isFile) {
                    cached.readBytes()
                } else {
                    val bytes = RuntimeStore.download(url)
                    cache.mkdirs()
                    cached.writeBytes(bytes)
                    bytes
                }
            },
        )
    } catch (e: Exception) {
        realError = e.message
    }
    check(realError == null, "the real CPython wasm build downloads, verifies and unpacks (error: $realError)")
    val realInstalled = realStore.installed(python)
    check(realInstalled != null, "the real python.wasm is where the catalog says it is")
    check(
        (realInstalled?.wasm?.length() ?: 0) > 10_000_000,
        "the unpacked interpreter is a real multi-megabyte wasm module",
    )
    // Where the stdlib actually sits comes from the entry's own PYTHONPATH rather than a guess:
    // `library` is `lib`, but CPython keeps its modules a version directory below that, and the
    // catalog already states which one.
    val stdlib = python.env["PYTHONPATH"]?.replace("{root}", realInstalled?.directory?.path ?: "")
    check(
        stdlib != null && File(stdlib, "os.py").isFile,
        "the real standard library came with it, where PYTHONPATH says it is ($stdlib)",
    )
}

fun main() {
    val node = findTool("node")
    val scratch = File(System.getProperty("java.io.tmpdir"), "pkgcheck-${ProcessHandle.current().pid()}")
    scratch.mkdirs()
    println("pkgcheck — the iOS phase-F corpus, ported (live registry; tarball cache ${tarballCache.path})")
    try {
        semverCorpus()
        tarCorpus(scratch)
        resolutionCorpus(scratch)
        installCorpus(scratch, node)
        aliasCorpus(scratch)
        substitutionCorpus()
        integrityCorpus(scratch)
        runtimeCorpus(scratch)
    } finally {
        scratch.deleteRecursively()
    }

    if (failures == 0) {
        println(
            "PACKAGE MANAGER: $checks checks — semver, tar/gzip/json, resolution vs pnpm, " +
                "real installs proven by real node, npm aliases, wasm substitution, integrity, " +
                "the runtime store against the real CPython build — MATCH",
        )
    } else {
        println("PACKAGE MANAGER: $failures of $checks checks disagree with the iOS gate — MISMATCH")
        exitProcess(1)
    }
}
