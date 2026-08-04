import org.jetbrains.kotlin.gradle.dsl.JvmTarget

// The gate for `:packages`. No test framework here, on purpose: invariant #4 is zero third-party
// dependencies, and JUnit is a third-party dependency. So the harness is a `main()` that runs a
// corpus and prints one verdict line, exactly like the Swift harnesses in `verify/` and like
// `:screencheck`.
//
//   cd kotlin && ANDROID_HOME=~/Library/Android/sdk ./gradlew :pkgcheck:run
//
// It talks to the REAL npm registry and runs the REAL pnpm and node on this machine, because
// that is what the iOS gate does and a mocked registry proves nothing about resolution.
plugins {
    alias(libs.plugins.kotlin.jvm)
    application
}

dependencies {
    implementation(project(":packages"))
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
    mainClass.set("com.reagentsystems.mouse.pkgcheck.MainKt")
}

tasks.named<JavaExec>("run") {
    // Gradle swallows a plain `println` stream into its own buffering otherwise; this harness is
    // meant to be watched while it downloads.
    standardOutput = System.out
    errorOutput = System.err
}
