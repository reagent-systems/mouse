pluginManagement {
    repositories {
        google {
            content {
                includeGroupByRegex("com\\.android.*")
                includeGroupByRegex("com\\.google.*")
                includeGroupByRegex("androidx.*")
            }
        }
        mavenCentral()
        gradlePluginPortal()
    }
}
dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "Mouse"
include(":app")
// The terminal screen engine and its headless gate. Both are pure Kotlin/JVM — see
// terminal/build.gradle.kts for why the screen does not live inside :app.
include(":terminal")
include(":screencheck")
// The package manager (npm registry, semver, integrity, tar) and its headless gate. Same shape,
// same reason — see packages/build.gradle.kts.
include(":packages")
include(":pkgcheck")
// The Node layer's portable half — the bootstrap extraction and its drift gate, the `__mouse`
// bridge protocol, the process globals and the event loop's bookkeeping — and its headless gate.
// The WebView that actually runs the engine is framework, so it lives in `:app`; see
// node/build.gradle.kts for where the line is drawn and why.
include(":node")
include(":nodecheck")
// `msh` itself — the word layer AND the language (phase A) — and its differential gate. Pure
// Kotlin for the same reason as the three above; see shell/build.gradle.kts.
include(":shell")
include(":shellcheck")
