# Releasing Mouse

Releases are cut from **`main`** by pushing a version tag. A GitHub Action
([`.github/workflows/release.yml`](.github/workflows/release.yml)) then builds
both apps and drafts a GitHub Release with the artifacts attached.

## Versioning

SemVer (`MAJOR.MINOR.PATCH`), pre-1.0 — minor bumps may include breaking
changes; `v0.x` maps to the roadmap milestones. Keep the two apps' versions
in step:

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
   simulator app, and opens a **draft** GitHub Release with generated notes.
5. Review the draft, paste in the changelog highlights, and publish.

You can also trigger it from the Actions tab (**Release → Run workflow**)
with a tag name, without pushing a tag.

## What ships in a release

| Asset | What it is | Who it's for |
|---|---|---|
| `mouse-android-vX.Y.Z.apk` | Debug-signed APK | Sideload on any device (`adb install`) or an emulator |
| `mouse-ios-sim-vX.Y.Z.zip` | Simulator `.app` | Reviewers running it in the iOS Simulator without Xcode |

The iOS asset is a **simulator** build. A device-installable `.ipa` for
TestFlight/App Store needs Apple signing, which requires secrets this repo
does not yet carry:

- `APPLE_CERTIFICATE_P12` + `APPLE_CERTIFICATE_PASSWORD` (a Distribution cert)
- `APPLE_PROVISIONING_PROFILE`
- `APP_STORE_CONNECT_KEY` (for `xcrun altool`/`notarytool` upload)

When those are added as repository secrets, extend the `ios` job to sign,
export an `.ipa`, and (optionally) upload to TestFlight. Until then, the
App Store path is tracked on the [roadmap](ROADMAP.md) (v1.0).
