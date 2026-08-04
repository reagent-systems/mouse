import org.jetbrains.kotlin.gradle.dsl.JvmTarget

// The terminal screen engine, as a PURE Kotlin/JVM module — no Compose, no `android.*`, no
// third-party anything (AGENTS.md invariant #4).
//
// Why it is its own module rather than another file in `:app`: the iOS side learned that logic
// sharing a file with UI is logic no harness can reach. Phase T only became verifiable there
// once TerminalScreen was Foundation-only, and the same rule decides the shape here — this
// module exists so the screen can be gated (`./gradlew :screencheck:run`) without an emulator,
// an Activity, or a Compose test rule.
plugins {
    alias(libs.plugins.kotlin.jvm)
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
