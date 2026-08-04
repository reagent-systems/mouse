import org.jetbrains.kotlin.gradle.dsl.JvmTarget

// `msh` — the shell, as a PURE Kotlin/JVM module: no Compose, no `android.*`, no third-party
// anything (AGENTS.md invariant #4).
//
// Why it moved out of `:app`: it was the last shared component with no gate at all. `verify/shell`
// gates the iOS shell DIFFERENTIALLY — every script runs through msh and through the real
// `/bin/sh` and the two are compared — and that harness cannot be pointed at a class that imports
// Compose. Same reasoning as `:terminal`, `:packages` and `:node` before it, and the same payoff:
// `./gradlew :shellcheck:run` runs the identical corpus with no emulator in sight.
//
// Deliberately free of kotlinx-coroutines, like `:packages`: the API is BLOCKING and callers wrap
// it in `withContext(Dispatchers.IO)`. Cancellation — which a streaming `ping` and `sleep` need,
// and which `Task.isCancelled` supplies on iOS — arrives as `Context.isActive`, a lambda the app
// closes over its Job. A gate that must run on a bare JVM has no business depending on an `:app`
// artifact to ask whether it was interrupted.
plugins {
    alias(libs.plugins.kotlin.jvm)
}

dependencies {
    // `TerminalProgram`/`PagerProgram`: `less` hands the terminal a full-screen program.
    implementation(project(":terminal"))
    // `RuntimeCatalog`/`RuntimeStore`: `pkg` installs language runtimes.
    implementation(project(":packages"))
}

java {
    // Match `:app` exactly: an Android module compiled for 11 cannot consume a 21-byte-code jar.
    sourceCompatibility = JavaVersion.VERSION_11
    targetCompatibility = JavaVersion.VERSION_11
}

kotlin {
    compilerOptions {
        jvmTarget.set(JvmTarget.JVM_11)
    }
}
