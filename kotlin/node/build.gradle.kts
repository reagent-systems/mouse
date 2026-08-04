import org.jetbrains.kotlin.gradle.dsl.JvmTarget

// The portable half of the Node layer, as a PURE Kotlin/JVM module — no Compose, no `android.*`,
// no third-party anything (AGENTS.md invariant #4).
//
// The Node layer's host side is a WebView, which is Android framework and cannot live here. What
// CAN live here is everything around it: the bootstrap extraction (and therefore the drift gate),
// the `__mouse` bridge protocol, the process globals the bootstrap reads before it runs, and the
// event loop's bookkeeping. That split is the same one `:terminal` and `:packages` made — logic
// that shares a file with UI is logic no harness can reach — and it is what lets
// `./gradlew :nodecheck:run` gate the layer without an emulator.
plugins {
    alias(libs.plugins.kotlin.jvm)
}

dependencies {
    // For `Json` only, and the reason is invariant #4 rather than convenience. Module resolution
    // reads package.json — "exports", "main", "type", "imports" — and stat/readdir answers cross
    // the `@JavascriptInterface` boundary as JSON because that boundary carries nothing else.
    // `org.json` is Android framework and absent from the JDK, so using it would cost a
    // third-party artifact AND stop this module building off-device; `:packages` already carries
    // the hand-written reader/writer written for exactly that reason, and a second copy here
    // would be one more thing to drift.
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
