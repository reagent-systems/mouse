#!/usr/bin/env bash
# Idempotent Cloud Agent bootstrap for Mouse.
#
# The iOS app (swift/) is macOS/Xcode-only and cannot build here; on Linux the
# buildable/runnable surfaces are the Android app (kotlin/), the marketing site
# (site/), and the Node-backed verify fixtures (verify/). This script provisions
# the one toolchain the default image lacks — the Android SDK — and primes the
# Gradle and npm caches so the first build is warm.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-$HOME/android-sdk}"
CMDLINE_TOOLS_VERSION="11076708"   # command-line tools 12.0 (linux)
PLATFORM="platforms;android-35"
BUILD_TOOLS="build-tools;35.0.0"

echo "==> Android SDK root: $ANDROID_SDK_ROOT"
mkdir -p "$ANDROID_SDK_ROOT"

sdkmanager_bin="$ANDROID_SDK_ROOT/cmdline-tools/latest/bin/sdkmanager"

if [ ! -x "$sdkmanager_bin" ]; then
  echo "==> Installing Android command-line tools ($CMDLINE_TOOLS_VERSION)"
  tmp_zip="$(mktemp --suffix=.zip)"
  curl -fsSL -o "$tmp_zip" \
    "https://dl.google.com/android/repository/commandlinetools-linux-${CMDLINE_TOOLS_VERSION}_latest.zip"
  rm -rf "$ANDROID_SDK_ROOT/cmdline-tools/tmp"
  mkdir -p "$ANDROID_SDK_ROOT/cmdline-tools/tmp"
  unzip -q "$tmp_zip" -d "$ANDROID_SDK_ROOT/cmdline-tools/tmp"
  rm -rf "$ANDROID_SDK_ROOT/cmdline-tools/latest"
  mv "$ANDROID_SDK_ROOT/cmdline-tools/tmp/cmdline-tools" "$ANDROID_SDK_ROOT/cmdline-tools/latest"
  rm -rf "$ANDROID_SDK_ROOT/cmdline-tools/tmp" "$tmp_zip"
else
  echo "==> Android command-line tools already present"
fi

export ANDROID_SDK_ROOT
export ANDROID_HOME="$ANDROID_SDK_ROOT"
export PATH="$ANDROID_SDK_ROOT/cmdline-tools/latest/bin:$ANDROID_SDK_ROOT/platform-tools:$PATH"

echo "==> Accepting SDK licenses"
yes | sdkmanager --licenses >/dev/null 2>&1 || true

echo "==> Installing SDK packages: platform-tools, $PLATFORM, $BUILD_TOOLS"
sdkmanager --install "platform-tools" "$PLATFORM" "$BUILD_TOOLS" >/dev/null

# Point Gradle at the SDK without relying on process env (environment.json has
# no env field). local.properties is gitignored, so this stays out of the repo.
echo "sdk.dir=$ANDROID_SDK_ROOT" > "$REPO_ROOT/kotlin/local.properties"
echo "==> Wrote kotlin/local.properties"

echo "==> Priming Gradle (assembleDebug)"
( cd "$REPO_ROOT/kotlin" && ./gradlew --no-daemon assembleDebug )

echo "==> Bootstrap complete"
