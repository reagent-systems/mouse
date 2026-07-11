# CLAUDE.md

Read [AGENTS.md](AGENTS.md) — it is the agent contract for this repository:
build commands, invariants, the landmine map, concurrency house style, and
process rules. Everything there applies to you.

Quick anchors:

- After adding/removing/renaming source files: `cd swift && xcodegen generate`
- Build check: `xcodebuild -project swift/Mouse.xcodeproj -scheme Mouse
  -destination 'generic/platform=iOS Simulator' build`
- The gesture law and the focused-editor stand-down are architecture — never
  regress them.
- No demo scaffolding; no leftover diagnostics; docs move with behavior.
