# Mouse for Android

The native Android app, in Kotlin + Jetpack Compose. Same product, same
design language ([DESIGN.md](../DESIGN.md)), same interaction spec as the
Swift app ([swift/README.md](../swift/README.md)) — built natively for its
platform, per the no-cross-platform-frameworks rule.

## Building

Requirements: **JDK 21** and the **Android SDK** (Android Studio installs both).

Android Studio: open this `kotlin/` folder. CLI:

```sh
cd kotlin
./gradlew assembleDebug
```

On macOS, if Gradle can't find the SDK:

```sh
ANDROID_HOME=~/Library/Android/sdk ./gradlew assembleDebug
```

Toolchain: Gradle 8.14, AGP 8.10, Kotlin 2.0, Compose (BOM 2024.09),
minSdk 26 / target 35. Zero third-party libraries beyond the platform +
Compose + coroutines — even tar/gzip (`GZIPInputStream` + a hand-written tar
reader), JSON (`org.json`), HTTP (`HttpURLConnection`), and checksums
(`MessageDigest`) are the SDK's own.

## Running on an emulator

### Android Studio (easiest)

1. Install [Android Studio](https://developer.android.com/studio).
2. **File → Open** → select this `kotlin/` folder (not the repo root).
3. **Tools → Device Manager → Create Device** — pick a phone (e.g. Pixel 9)
   and a recent system image (API 35 or similar). Start the virtual device.
4. Click **Run** (green play button). Android Studio builds, installs, and
   launches the app on the emulator.

### CLI

Build the APK (see above), then boot an emulator and install:

```sh
# macOS — add SDK tools to PATH if needed
export ANDROID_HOME=~/Library/Android/sdk
export PATH="$ANDROID_HOME/emulator:$ANDROID_HOME/platform-tools:$PATH"

# List virtual devices, then boot one (use a name from the list)
emulator -list-avds
emulator -avd Pixel_9 &

adb wait-for-device
adb install -r app/build/outputs/apk/debug/app-debug.apk
adb shell am start -n com.reagentsystems.mouse/.MainActivity
```

On Windows (PowerShell), set `ANDROID_HOME` to
`$env:LOCALAPPDATA\Android\Sdk` and add `\emulator` and `\platform-tools`
to `PATH` before the same `adb` / `emulator` commands.

### If something fails

| Problem | Fix |
|---|---|
| `emulator` or `adb` not found | Add `$ANDROID_HOME/emulator` and `.../platform-tools` to `PATH` |
| No AVDs listed | Create one in Android Studio → Device Manager |
| Gradle / SDK errors | Open `kotlin/` in Android Studio once; let it sync and download SDK components |
| Emulator won't start | Enable CPU virtualization in BIOS, or use a physical device with USB debugging |

## Parity

Feature parity with the iOS app, built natively in Compose:

- **The gesture shell** — ring/lane/strip, the gesture law (axis-locked drag
  detectors: horizontal drives the shell, vertical is content), edge-swipe
  ring travel, divider resize, pinch to add/remove lanes
- **Onboarding ring** — the self-teaching lesson chain (Swipe? → Drag? → …)
- **GitHub sign-in** — OAuth Device Flow against a classic OAuth App with
  `repo` scope (all the user's repos, no installation step); tokens in
  app-private storage
- **Workspaces** — clone via the tarball API, extracted by the hand-written
  `TarGz` (platform GZIP + hand tar); one workspace per repo, app-wide
- **Files / Viewer / Graph** — lazy tree, in-place editing with shared
  `FileBuffer`s across rings, the commit graph with colored rails
- **Push / pull** — corner chips; one real commit via the Git Data API
- **Persistence** — the whole strip survives relaunch (JSON snapshot)
- **Terminal** — two engines behind the switcher: `msh` (the same
  from-scratch shell as iOS, ported) and the device's **real
  `/system/bin/sh`** as a persistent process — Android's honest advantage

## Known Android nuances

- **Edge-swipe vs. the system back gesture.** On gesture-navigation devices,
  Android reserves the screen edges for the back gesture. The ring edge-swipe
  claims those bands with `Modifier.systemGestureExclusion()` (the standard
  API), but the OS caps exclusion at 200 dp per edge, so on gesture-nav a
  swipe from the extreme edge may still go back. This is inherently a
  real-device / real-finger behavior (`adb input` near the edge is
  intercepted by the system's back-gesture handler and can't test it
  faithfully). No conflict on 3-button navigation.
- **Pixels ring-swipe in the gaps.** On Google Pixels (runtime check:
  `Build.MANUFACTURER == "Google"` + `Build.MODEL` contains "Pixel", one APK
  for everyone), the edge strips stand down and ring travel moves to the
  negative space between containers: a **horizontal drag in a divider gap**
  swipes the ring. The gap keeps both gestures — the axis-locked detectors
  mean vertical still resizes lanes, horizontal swipes rings, and whichever
  axis crosses touch slop first claims the drag. Direction locks on the
  first movement so a mid-drag wobble can't flip neighbors. A one-lane ring
  has no gap, so the edge strips remain its travel path there.

## Platform differences (by design)

- **`sh` engine**: Android runs the real system shell; iOS can't (no
  fork/exec), so iOS has only `msh`. Both platforms share `msh`.
- **`ping`**: uses `InetAddress.isReachable` (no raw sockets / NDK); iOS
  hand-builds ICMP packets on an unprivileged datagram socket.
- **Token storage**: app-private `SharedPreferences` (the Android sandbox);
  iOS uses the Keychain. A Keystore upgrade is a future nicety.
