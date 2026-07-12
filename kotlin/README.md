# Mouse for Android

The native Android app, in Kotlin + Jetpack Compose. Same product, same
design language ([DESIGN.md](../DESIGN.md)), same interaction spec as the
Swift app ([swift/README.md](../swift/README.md)) — built natively for its
platform, per the no-cross-platform-frameworks rule.

## Building

Android Studio: open this `kotlin/` folder. CLI:

```sh
./gradlew assembleDebug     # requires an Android SDK (ANDROID_HOME)
```

Toolchain: Gradle 8.14, AGP 8.10, Kotlin 2.0, Compose (BOM 2024.09),
minSdk 26 / target 35.

## What exists

The seed: one Mouse-styled container (white canvas, black 32 dp-radius
panel, IBM Plex Mono) holding a **real terminal** — a persistent
`/system/bin/sh` process whose state (cwd, variables) survives between
commands. This is the platform advantage the terminal roadmap builds on:
Android apps may run the system shell, so where iOS gets Mouse's
from-scratch `msh`, Android's "sh" engine is the genuine article.

## What's next (tracks the Swift app)

1. The ring/lane shell and the gesture law
2. Onboarding lessons, persistence
3. Workspaces (GitHub Device Flow, tarball download), Files, Viewer, Graph
4. The `msh` engine alongside `sh`, and the terminal engine switcher
