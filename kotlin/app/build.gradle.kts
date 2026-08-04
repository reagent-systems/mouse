plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
}

android {
    namespace = "com.reagentsystems.mouse"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.reagentsystems.mouse"
        minSdk = 26
        targetSdk = 35
        versionCode = 1
        versionName = "0.1"
    }

    buildTypes {
        release {
            isMinifyEnabled = false
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }
    kotlinOptions {
        jvmTarget = "11"
    }
    buildFeatures {
        compose = true
    }
}

/**
 * The language-runtime catalog ships as an asset, COPIED from `swift/Runtimes.json` rather than
 * duplicated into this tree. The whole "a language is data" claim rests on there being exactly
 * one catalog in the repo — a second copy under kotlin/ would let the two platforms disagree
 * about what `pkg install python` fetches, which is the one place they must not.
 *
 * Same reasoning as `:screencheck` reading `verify/` fixtures directly instead of copying them.
 */
val runtimeCatalog by tasks.registering(Copy::class) {
    from(rootProject.file("../swift/Runtimes.json"))
    into(layout.buildDirectory.dir("generated/runtimeCatalog"))
}

android.sourceSets.getByName("main").assets.srcDir(layout.buildDirectory.dir("generated/runtimeCatalog"))

tasks.matching { it.name.startsWith("merge") && it.name.endsWith("Assets") }.configureEach {
    dependsOn(runtimeCatalog)
}

dependencies {
    // The terminal screen engine. It is a separate pure-JVM module so it can be gated headlessly
    // — see terminal/build.gradle.kts.
    implementation(project(":terminal"))
    // The package manager, and `TarGz` with it (the workspace clone unpacks through the same
    // reader the npm installer does). Pure-JVM for the same reason — see packages/.
    implementation(project(":packages"))
    // The Node layer's portable half: the bootstrap asset's extraction (and drift gate), the
    // `__mouse` bridge protocol, the process globals and the event loop's bookkeeping. The
    // WebView that runs the engine is in this module (`nodehost/`) because it is framework.
    implementation(project(":node"))
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.activity.compose)
    implementation(platform(libs.androidx.compose.bom))
    implementation(libs.androidx.ui)
    implementation(libs.androidx.foundation)
    implementation(libs.androidx.material3)
    implementation(libs.kotlinx.coroutines.android)
}
