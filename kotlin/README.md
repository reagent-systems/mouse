# Mouse for Android

The native Android app, in Kotlin + Jetpack Compose. Same product, same
design language ([DESIGN.md](../DESIGN.md)), same interaction spec as the
Swift app ([swift/README.md](../swift/README.md)) — built natively for its
platform, per the no-cross-platform-frameworks rule.

## Building

Android Studio: open this `kotlin/` folder. CLI:

```sh
ANDROID_HOME=~/Library/Android/sdk ./gradlew assembleDebug
```

Toolchain: Gradle 8.14, AGP 8.10, Kotlin 2.0, Compose (BOM 2024.09),
minSdk 26 / target 35. Zero third-party libraries beyond the platform +
Compose + coroutines — even tar/gzip (`GZIPInputStream` + a hand-written tar
reader), JSON (`org.json`), HTTP (`HttpURLConnection`), and checksums
(`MessageDigest`) are the SDK's own.

## Parity

Feature parity with the iOS app, built natively in Compose:

- **The gesture shell** — ring/lane/strip, the gesture law (axis-locked drag
  detectors: horizontal drives the shell, vertical is content), edge-swipe
  ring travel, divider resize, pinch to add/remove lanes
- **Onboarding ring** — the self-teaching lesson chain (Swipe? → Drag? → …)
- **GitHub sign-in** — OAuth Device Flow; tokens in app-private storage
- **Workspaces** — clone via the tarball API, extracted by the hand-written
  `TarGz` (platform GZIP + hand tar); one workspace per repo, app-wide
- **Files / Viewer / Graph** — lazy tree, in-place editing with shared
  `FileBuffer`s across rings, the commit graph with colored rails
- **Push / pull** — corner chips; one real commit via the Git Data API
- **Persistence** — the whole strip survives relaunch (JSON snapshot)
- **Terminal** — two engines behind the switcher: `msh` (the same
  from-scratch shell as iOS, ported) and the device's **real
  `/system/bin/sh`** as a persistent process — Android's honest advantage

## Platform differences (by design)

- **`sh` engine**: Android runs the real system shell; iOS can't (no
  fork/exec), so iOS has only `msh`. Both platforms share `msh`.
- **`ping`**: uses `InetAddress.isReachable` (no raw sockets / NDK); iOS
  hand-builds ICMP packets on an unprivileged datagram socket.
- **Token storage**: app-private `SharedPreferences` (the Android sandbox);
  iOS uses the Keychain. A Keystore upgrade is a future nicety.
