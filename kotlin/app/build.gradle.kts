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

dependencies {
    // The terminal screen engine. It is a separate pure-JVM module so it can be gated headlessly
    // — see terminal/build.gradle.kts.
    implementation(project(":terminal"))
    // The package manager, and `TarGz` with it (the workspace clone unpacks through the same
    // reader the npm installer does). Pure-JVM for the same reason — see packages/.
    implementation(project(":packages"))
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.activity.compose)
    implementation(platform(libs.androidx.compose.bom))
    implementation(libs.androidx.ui)
    implementation(libs.androidx.foundation)
    implementation(libs.androidx.material3)
    implementation(libs.kotlinx.coroutines.android)
}
