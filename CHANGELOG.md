# Changelog

All notable changes to Mouse. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[SemVer](https://semver.org/) (`MAJOR.MINOR.PATCH`), pre-1.0 so minors may
carry breaking changes.

## [Unreleased]

### Added
- **Android app** (`kotlin/`) at feature parity with iOS, native Kotlin +
  Compose: the gesture shell, onboarding with idle "motion is the arrow"
  animations, GitHub sign-in, workspaces (native tar/gzip), Files/Viewer/
  Graph, push/pull, persistence, and a terminal with `msh` + the real
  system `sh` behind the engine switcher.
- **`msh` shell** on both platforms: quoting, variables, globs, pipes,
  redirection, `&&`/`||`, history, and ~50 built-ins (incl. `sed`, `diff`,
  `base64`, checksums).
- **Networking in the terminal**: `ping` (real ICMP), `curl`/`wget`,
  `sleep`, on async streaming-command machinery; any keypress interrupts a
  streaming command (the phone's Ctrl-C).
- Shared live `FileBuffer`s — rings viewing the same file share one document.
- Release + CI workflows building both apps.

### Fixed
- Selection-handle drags no longer drive the lane (CPU spike) — the shell
  stands down while the editor is focused.
- Lazy edge-panel mounting removes the edge-swipe memory doubling.

<!--
Release process: see RELEASING.md. When cutting a release, rename
[Unreleased] to the version + date and start a fresh [Unreleased] section.
-->
