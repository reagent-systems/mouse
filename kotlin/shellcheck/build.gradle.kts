import org.jetbrains.kotlin.gradle.dsl.JvmTarget

// The gate for `:shell`. No test framework here, on purpose: invariant #4 is zero third-party
// dependencies, and JUnit is a third-party dependency. So the harness is a `main()` that runs a
// corpus and prints one verdict line, exactly like `:screencheck`, `:pkgcheck` and `:nodecheck`.
//
//   cd kotlin && ANDROID_HOME=~/Library/Android/sdk ./gradlew :shellcheck:run
//
// It is DIFFERENTIAL, which is the whole point and is copied from `verify/shell/main.swift`: each
// script runs through msh AND through the real `/bin/sh` on this machine, each in its own scratch
// directory, and stdout plus exit status are compared. A shell gated against its own expectations
// proves only that it is self-consistent; gated against `/bin/sh` it proves the grammar is real.
plugins {
    alias(libs.plugins.kotlin.jvm)
    application
}

dependencies {
    implementation(project(":shell"))
}

java {
    sourceCompatibility = JavaVersion.VERSION_11
    targetCompatibility = JavaVersion.VERSION_11
}

kotlin {
    compilerOptions {
        jvmTarget.set(JvmTarget.JVM_11)
    }
}

application {
    mainClass.set("com.reagentsystems.mouse.shellcheck.MainKt")
}

tasks.named<JavaExec>("run") {
    // Gradle swallows a plain `println` stream into its own buffering otherwise.
    standardOutput = System.out
    errorOutput = System.err
}
