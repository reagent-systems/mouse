package com.reagentsystems.mouse.node

/**
 * The globals the bootstrap reads WHILE IT LOADS, and the script that sets them.
 *
 * `process.argv`, `process.env` and `process.cwd()` are captured at the top level of the
 * bootstrap's IIFE — `argv: __argv.slice()` — so these have to exist before the bootstrap is
 * evaluated, not after. On iOS they are set with `context.setObject(…)` right before
 * `evaluateScript(bootstrap)`; a WebView has no such door, so they are assigned by a preamble
 * script instead. Same names, same order, same meanings; [NodeEngine.installNativeBridge] on the
 * Swift side is the reference.
 *
 * Pure and therefore gradeable: `:nodecheck` compares the generated preamble against what the
 * bootstrap expects to read.
 */
data class NodeProcessConfig(
    /** `process.argv`. node's convention: [execPath, script, …args]. */
    val argv: List<String> = listOf("/usr/local/bin/node"),
    /** `process.env`. */
    val env: Map<String, String> = emptyMap(),
    /** `process.cwd()`. Workspace-virtual, as on iOS ("/" is the workspace root). */
    val cwd: String = "/",
    /** Seed text for stdin. */
    val stdin: String = "",
    /**
     * Is the seeded text ALL the input there will ever be? Only the host knows (AGENTS.md).
     * With no terminal and no pipe attached — 3a's only configuration — it is, and saying so is
     * what lets a program that reads stdin reach EOF instead of waiting forever.
     */
    val stdinIsComplete: Boolean = true,
    /** A pipe is not a terminal; `isTTY` false makes a program take its non-interactive path. */
    val isTty: Boolean = false,
    /** A piped child's stdio is bytes, carried through latin1. Not reachable until 3d. */
    val stdioBinary: Boolean = false,
    val ttyRows: Int = 24,
    val ttyColumns: Int = 80,
) {

    /**
     * `env` with the one entry the iOS engine adds for itself.
     *
     * napi-rs generates a loader that tries this platform's `.node` binary first and only falls
     * back to the package's WebAssembly build when told to. Android refuses to exec a downloaded
     * binary from app-private storage since API 29 (plans/android-parity.md), so as on iOS the
     * wasm fallback is not a preference here — it is the only reachable branch, and this is the
     * flag its own authors provide for saying so.
     */
    fun effectiveEnv(): Map<String, String> =
        if (env.containsKey("NAPI_RS_FORCE_WASI")) env
        else env + ("NAPI_RS_FORCE_WASI" to "true")

    /** The preamble. Must be evaluated after the `__mouse` shim and before the bootstrap. */
    fun globalsScript(): String {
        val q = HostBridge::jsString
        val argvLiteral = argv.joinToString(",") { q(it) }
        val envLiteral = effectiveEnv().entries
            .sortedBy { it.key }
            .joinToString(",") { "${q(it.key)}:${q(it.value)}" }
        return buildString {
            append("globalThis.__argv = [").append(argvLiteral).append("];\n")
            append("globalThis.__env = {").append(envLiteral).append("};\n")
            append("globalThis.__cwd = ").append(q(cwd)).append(";\n")
            append("globalThis.__stdin = ").append(q(stdin)).append(";\n")
            append("globalThis.__stdinIsComplete = ").append(stdinIsComplete).append(";\n")
            append("globalThis.__isTTY = ").append(isTty).append(";\n")
            append("globalThis.__stdioBinary = ").append(stdioBinary).append(";\n")
            append("globalThis.__ttyRows = ").append(ttyRows).append(";\n")
            append("globalThis.__ttyColumns = ").append(ttyColumns).append(";\n")
            // 3a runs no children and no workers; both surfaces refuse through the deferred
            // stubs, and these flags are what make the bootstrap not reach for them.
            append("globalThis.__hasIPC = false;\n")
            append("globalThis.__workerData = \"\";\n")
            append("globalThis.__isWorker = false;\n")
        }
    }

    companion object {
        /**
         * Every global the bootstrap reads before it has finished loading. The gate checks the
         * preamble against this list AND against the bootstrap text, so a global added on the iOS
         * side turns up as a red Android gate rather than as `undefined` inside the engine.
         */
        val REQUIRED_GLOBALS: List<String> = listOf(
            "__argv", "__env", "__cwd", "__stdin", "__stdinIsComplete", "__isTTY",
            "__stdioBinary", "__ttyRows", "__ttyColumns", "__hasIPC", "__workerData", "__isWorker",
        )
    }
}
