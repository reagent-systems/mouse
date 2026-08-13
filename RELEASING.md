# Releasing Mouse

Releases are cut from **`main`** by pushing a version tag. A GitHub Action
([`.github/workflows/release.yml`](.github/workflows/release.yml)) then builds
both apps and publishes a GitHub Release with the artifacts attached and
generated notes.

## Versioning

SemVer (`MAJOR.MINOR.PATCH`). Keep the two apps' versions in step:

- **iOS**: `MARKETING_VERSION` in [swift/project.yml](swift/project.yml)
  (re-run `xcodegen generate` after changing it).
- **Android**: `versionName` (and bump `versionCode` by 1) in
  [kotlin/app/build.gradle.kts](kotlin/app/build.gradle.kts).

## Cutting a release

1. Land everything for the release on `main` and make sure CI is green.
2. Bump the versions above and move the `## [Unreleased]` block in
   [CHANGELOG.md](CHANGELOG.md) to `## [x.y.z] - YYYY-MM-DD`, then start a
   fresh `## [Unreleased]`.
3. Commit, then tag and push:
   ```sh
   git tag v0.2.0
   git push origin main v0.2.0
   ```
4. The **Release** workflow runs, builds the Android APK and the iOS
   simulator app, and publishes a GitHub Release with generated notes and
   both artifacts attached.
5. Edit the published release to paste in the changelog highlights.

You can also trigger it from the Actions tab (**Release → Run workflow**)
with a tag name, without pushing a tag.

## What ships in a release

| Asset | What it is | Who it's for |
|---|---|---|
| `mouse-android-vX.Y.Z.apk` | Debug-signed APK | Sideload on any device (`adb install`) or an emulator |
| `mouse-ios-sim-vX.Y.Z.zip` | Simulator `.app` | Reviewers running it in the iOS Simulator without Xcode |

A `mouse-ios-vX.Y.Z.ipa` ships beside those: the `ios-ipa` job signs a device
build with the repository's Apple secrets —

- `APPLE_CERTIFICATE_P12` + `APPLE_CERTIFICATE_PASSWORD` (the Distribution cert)
- `APPLE_PROVISIONING_PROFILE` (an App Store profile for the bundle id)
- `APP_STORE_CONNECT_KEY` + `APP_STORE_CONNECT_KEY_ID` + `APP_STORE_CONNECT_ISSUER_ID`

Signing is manual and pinned to the uploaded profile: its plist supplies the
name, UUID and team at run time, so rotating a secret rotates the signing with
no workflow change. Every run VALIDATES the package against App Store Connect;
only a real tag push UPLOADS to TestFlight — a `workflow_dispatch` rehearsal
proves the whole path without publishing a build. Validation and upload need
the app record to exist in App Store Connect for the bundle id; until it does,
the validate step fails naming exactly that.

The certificate expires yearly. When the archive step starts failing with a
signing error, re-export the cert and replace `APPLE_CERTIFICATE_P12` — nothing
else changes.
