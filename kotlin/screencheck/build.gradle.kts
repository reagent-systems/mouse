import org.jetbrains.kotlin.gradle.dsl.JvmTarget

// The gate for `:terminal`. There is no test framework here on purpose: invariant #4 is zero
// third-party dependencies, and JUnit is a third-party dependency. So the harness is a `main()`
// that runs a corpus and prints one verdict line, exactly like the Swift harnesses in `verify/`.
//
//   cd kotlin && ANDROID_HOME=~/Library/Android/sdk ./gradlew :screencheck:run
plugins {
    alias(libs.plugins.kotlin.jvm)
    application
}

dependencies {
    implementation(project(":terminal"))
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
    mainClass.set("com.reagentsystems.mouse.screencheck.MainKt")
}

tasks.named<JavaExec>("run") {
    // The corpus reads the SAME fixtures the iOS suite gates against (`verify/tty/cc-frame.*`,
    // `verify/widechars/widths.txt`). Copying them here would let the two sides drift, which is
    // the one thing a parity gate must not allow — so the repo root is handed in instead.
    systemProperty("mouse.repo.root", rootProject.projectDir.parentFile.absolutePath)
}
