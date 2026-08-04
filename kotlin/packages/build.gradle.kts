import org.jetbrains.kotlin.gradle.dsl.JvmTarget

// The package manager (phase F), as a PURE Kotlin/JVM module — no Compose, no `android.*`, no
// third-party anything (AGENTS.md invariant #4). Not even `org.json`: that ships inside the
// Android framework but not the JDK, so depending on it here would cost a third-party artifact
// AND make the module unbuildable off-device. `Json.kt` is the answer, same disposition as the
// hand-written tar.
//
// Why it is its own module rather than another file in `:app`: the whole npm install path has to
// be gatable without an emulator, exactly as `:terminal` is — `./gradlew :pkgcheck:run` resolves
// against the real registry, installs real packages and verifies their integrity, and none of
// that can be reached from a file that imports Compose.
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
