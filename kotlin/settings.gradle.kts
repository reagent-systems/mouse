pluginManagement {
    repositories {
        google {
            content {
                includeGroupByRegex("com\\.android.*")
                includeGroupByRegex("com\\.google.*")
                includeGroupByRegex("androidx.*")
            }
        }
        mavenCentral()
        gradlePluginPortal()
    }
}
dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "Mouse"
include(":app")
// The terminal screen engine and its headless gate. Both are pure Kotlin/JVM — see
// terminal/build.gradle.kts for why the screen does not live inside :app.
include(":terminal")
include(":screencheck")
// The package manager (npm registry, semver, integrity, tar) and its headless gate. Same shape,
// same reason — see packages/build.gradle.kts.
include(":packages")
include(":pkgcheck")
