# Contributing to Mouse

Thanks for wanting to work on this. Mouse is small, opinionated, and moving
fast — this document is what you need to be productive without stepping on
the things that make it work.

## Setup

Two native apps; build the one you're touching (full build/run instructions,
including the simulator and emulator, are in the [README](README.md)).

**iOS (`swift/`)** — macOS + **Xcode 16+** + `brew install xcodegen`:

```sh
cd swift && xcodegen generate && open Mouse.xcodeproj
```

`Mouse.xcodeproj` is **generated** from [swift/project.yml](swift/project.yml).
Never hand-edit the project file; change `project.yml` and re-run
`xcodegen generate`. Re-run it whenever you add, remove, or rename a source
file. The regenerated `.xcodeproj` is committed, so include it in your PR if
it changed.

**Android (`kotlin/`)** — **JDK 21** + the Android SDK (open `kotlin/` in
Android Studio, or `./gradlew assembleDebug`). No generated project file.

The two apps share no code — a feature added to one should be mirrored in the
other (or the PR should say why not). Parity is by faithful re-implementation
(`Shell.swift` ↔ `MouseShell.kt`, `CarouselDeck.swift` ↔ `Model.kt`, …).

## Ground rules

- **The gesture law is architecture, not preference.** One-finger horizontal
  drags and all two-finger gestures belong to the shell, everywhere; content
  gets taps, vertical scrolling, and the keyboard (and while an editor is
  focused, drags on it belong to the text). Any input-handling change must
  say, in the PR description, how it upholds the law.
- **Zero dependencies is a feature.** The app ships with no third-party code
  — even tar/gzip extraction is hand-written against the platform. Adding a
  dependency needs a discussion issue first, with the "what would it take to
  not add it" answer written down. (Planned exceptions live on the
  [roadmap](ROADMAP.md): libgit2, esbuild, Runestone.)
- **Experiment freely; merge carefully.** Spike on branches, keep whole
  experimental directions alive as `*-experiments` branches, use whatever
  throwaway UI and diagnostics help you explore. The bar lives at `main`:
  what merges is feel-tested on a real device, and it lands clean — no
  leftover demo scaffolding or diagnostic code.
- **Comments state constraints, not narration.** The codebase leans on
  comments that explain *why the obvious alternative fails* (there are
  several load-bearing ones — see [AGENTS.md](AGENTS.md) for the map).
  Match that: no "this line does X" comments, no change-log comments.
- **Docs move with behavior.** If your change alters what a gesture does or
  what a container can do, update [swift/README.md](swift/README.md)
  (Gestures / Functionality sections). If it changes how things look or move,
  update [DESIGN.md](DESIGN.md).

## Verifying changes

There is no test target yet (unit tests for the pure cores — tar/gzip, graph
layout — are welcome). Merging to `main` means the change was tested for
**function and feel**:

1. Build clean — iOS: `xcodebuild -project swift/Mouse.xcodeproj -scheme
   Mouse -destination 'generic/platform=iOS Simulator' build`; Android:
   `cd kotlin && ./gradlew assembleDebug`. Build the platform(s) you touched.
2. Exercise what you touched **plus the gesture matrix near it**: lane
   swipe, edge swipe, divider drag, pinch, and — if you were near the
   editor — tap-to-focus, selection drag, tap-outside dismiss.
3. **Feel it on a real device.** Gesture latency, spring weight, keyboard
   behavior, and performance are the product; the simulator can't vouch for
   them (and lies about CPU with the keyboard up — see
   [AGENTS.md](AGENTS.md)). If it feels worse, it isn't done, even if it
   works.
4. Force-quit and relaunch: the strip must restore (persistence breaks are
   easy to miss and painful to bisect).

CI builds every push and PR; a red build blocks review.

## Where work happens

Big directions live on long-running **product branches** — `vs-code`,
`cursor`, `n8n`, and friends (see [ROADMAP.md](ROADMAP.md)). A product
branch is an exploration space with loose rules; `main` is where slices land
once they're feel-tested and clean. Fixes and cross-cutting foundations go
straight at `main`; feature work for a product direction targets its branch.

## Pull requests

- Branch from `main` (or the relevant product branch); keep PRs scoped to
  one idea.
- Describe *what changed and why*, the gesture-law impact (or "none"), and
  what you verified on device/simulator.
- **Screenshots or a short clip for anything visible** — this is a UI
  project, and motion changes especially can only be judged by watching
  them. Attach media directly in the PR description (GitHub hosts it);
  exploration artifacts worth keeping beyond the PR go in `sketches/`.
- Maintainers squash-merge; write the PR title like a commit subject.

## Reporting issues

A good bug report for a gesture app: device, iOS version, the ring/lane
state you were in (a screenshot of the strip helps), what you did with your
fingers, what happened, what you expected. Crash logs and files-that-triggered
welcome.
