package com.reagentsystems.mouse

import android.content.Context
import com.reagentsystems.mouse.packages.RuntimeCatalog
import com.reagentsystems.mouse.packages.RuntimeStore
import com.reagentsystems.mouse.shell.MouseShell
import java.io.File

/**
 * The app's one runtime store, and the catalog behind it.
 *
 * The catalog is `swift/Runtimes.json`, copied into assets by a Gradle task rather than duplicated
 * into this tree (see app/build.gradle.kts) — one file, both platforms, so "a language is data"
 * stays a fact rather than a slogan.
 *
 * Installs go under `filesDir`, never the cache: Android evicts caches under storage pressure, and
 * a language silently disappearing mid-project is worse than the disk it costs.
 */
object Runtimes {
    private var loaded: MouseShell.RuntimeSupport? = null

    /**
     * The application context, kept for the one other thing a terminal needs and cannot reach: a
     * WebView, which `NodeRunner` builds per program. `TerminalSession` is constructed from a
     * workspace root and has no Context of its own, and threading one down to it would put an
     * Android type through the model layer for a single use.
     */
    private var application: Context? = null

    /** Null until [attach] has run — a shell with no store answers honestly instead of crashing. */
    val support: MouseShell.RuntimeSupport? get() = loaded

    /** Null in the same window, and for the same reason: the shell then reports no engine. */
    val appContext: Context? get() = application

    fun attach(context: Context) {
        application = context.applicationContext
        if (loaded != null) return
        val text = runCatching {
            context.assets.open("Runtimes.json").use { it.readBytes().toString(Charsets.UTF_8) }
        }.getOrNull() ?: return
        val catalog = runCatching { RuntimeCatalog.parse(text) }.getOrNull() ?: return
        loaded = MouseShell.RuntimeSupport(catalog, RuntimeStore(File(context.filesDir, "runtimes")))
    }
}
