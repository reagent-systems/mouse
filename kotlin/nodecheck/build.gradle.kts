import org.jetbrains.kotlin.gradle.dsl.JvmTarget

// The gate for `:node`. No test framework here, on purpose: invariant #4 is zero third-party
// dependencies, and JUnit is a third-party dependency. So the harness is a `main()` that runs a
// corpus and prints one verdict line, exactly like the Swift harnesses in `verify/` and like
// `:screencheck` and `:pkgcheck`.
//
//   cd kotlin && ANDROID_HOME=~/Library/Android/sdk ./gradlew :nodecheck:run
//
// The load-bearing check is DRIFT: it extracts the JS bootstrap out of `swift/Mouse/NodeEngine.swift`
// at check time and compares it to `kotlin/app/src/main/assets/node-bootstrap.js`. A copy that
// silently diverges from the iOS original is worse than no copy, so the copy is never trusted —
// it is re-derived and diffed on every run, the same way `:screencheck` reads `verify/` fixtures
// instead of copying them.
//
// `--sync` rewrites the asset from the Swift source instead of grading it. The writer and the
// reader are then the same code, which is the only way the transform cannot be wrong in one
// direction only.
plugins {
    alias(libs.plugins.kotlin.jvm)
    application
}

dependencies {
    implementation(project(":node"))
    // Declared here rather than leaned on transitively. Since milestone 3c the socket, DNS and
    // HTTP layers answer in JSON — that is the only shape `@JavascriptInterface` carries — so the
    // harness has to READ what they produce, and it reads it with the same hand-written reader
    // `:node` writes it with. Grading a JSON answer with a second parser would be grading two
    // things at once.
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
    mainClass.set("com.reagentsystems.mouse.nodecheck.MainKt")
}

tasks.named<JavaExec>("run") {
    // The harness reads the SHIPPING Swift source and the SHIPPING asset — never a copy — so the
    // repo root is handed in the way `:screencheck` hands in `verify/`.
    systemProperty("mouse.repo.root", rootProject.projectDir.parentFile.absolutePath)
    standardOutput = System.out
    errorOutput = System.err
    // `./gradlew :nodecheck:run --args=--sync` regenerates the asset.
}
