# AGENTS.md — the contract for AI agents working on Mouse

Humans should read this too: it doubles as the map of load-bearing decisions
that are cheap to break and expensive to rediscover. Every entry here was
paid for.

## Commands

```sh
# after adding/removing/renaming ANY source file:
cd swift && xcodegen generate

# build (the only automated check today):
xcodebuild -project swift/Mouse.xcodeproj -scheme Mouse \
  -destination 'generic/platform=iOS Simulator' build
```

Never edit `Mouse.xcodeproj` directly — it is generated from
`swift/project.yml`. There is no test target; verification is running the
app (see CONTRIBUTING.md). One exception: `Shell.swift` is deliberately
Foundation-only, so interpreter changes can be verified headlessly —
compile it with a scratch `main.swift` of assertions via `swiftc` and run.

Android (`kotlin/`): `cd kotlin && ANDROID_HOME=~/Library/Android/sdk
./gradlew assembleDebug`. Standard Gradle project — Android Studio opens
the `kotlin/` folder directly.

## Invariants

1. **The gesture law.** One-finger horizontal drags + all two-finger gestures
   belong to the shell, everywhere. Content gets taps, vertical scrolling,
   and the keyboard. Refinement: while the editor is focused
   (`deck.editorFocused`), *every* drag on that container belongs to the text
   — selection handles and caret drags must never drive the lane
   (`CarouselLane.swipe` gates on it; breaking this pegs the CPU and swaps
   containers mid-selection).
2. **Identity registries, main-thread only.** One `Workspace` per repo
   (`Workspace.byRepo`), one `FileBuffer` per (workspace, file)
   (`FileBuffer.byFile`), one shared `ContainerContent` per synced kind
   (`ContainerContent.sharedByKind`). All are `nonisolated(unsafe)` static
   dictionaries touched only from the main thread — follow the existing
   pattern; do not introduce actors or locks around them piecemeal.
3. **Container-identity rendering.** The visible panel set renders through a
   `ForEach` keyed on **container id** with one uniform modifier chain
   (`CarouselLane`). A commit moves the same view instance to a new offset.
   Keying by slot/position reintroduces the unload flash.
4. **Zero third-party dependencies** until the roadmap says otherwise.
5. **Native per platform, no bridges.** Two apps: `swift/` (iOS/iPadOS) and
   `kotlin/` (Android) — each built natively against its own platform. No
   web builds, no Capacitor/React Native/Flutter; that direction was removed
   deliberately. Big feature directions live on product branches (`vs-code`,
   `cursor`, `n8n`, … — see ROADMAP.md), and slices merge to `main` when
   feel-tested.

## Landmines — do not "fix" these

- `ForegroundView` measures with **`containerRelativeFrame`**. Replacing it
  with `GeometryReader` breaks lane layout: the oversized ASCII background
  sibling inflates the reported size. The comment in the file is not
  decorative.
- **`KeyboardFloatingHost`** (`MouseApp.swift`) sets
  `safeAreaRegions = .container` on a bridged `UIHostingController`. This is
  the *only* working way to keep the keyboard from shifting the app, because
  `containerRelativeFrame` measures the window container, which the keyboard
  shrinks at the source — `ignoresSafeArea(.keyboard)` cannot reach it.
- **`TerminalPromptField`** returns `false` from `textFieldShouldReturn` so
  the keyboard never dips between commands. SwiftUI's `TextField` always
  resigns on submit; that's why it's UIKit.
- **`FileBuffer.suppressNextChange`**: programmatic text loads must not mark
  files modified (viewing a file once queued it for commit). Set it before
  any non-user assignment to `text`.
- **`FileBuffer.ensure`** deliberately *discards* dirty text when a pull
  bumped `treeVersion` — flushing first would overwrite the freshly pulled
  file with stale text. The pull UI already warned the user.
- Terminal scrollback uses **`defaultScrollAnchor(.bottom)`** — manual
  `scrollTo` against not-yet-wrapped lines parks output offscreen.
- The ASCII backdrop's `TimelineView(.animation)` is intentionally off
  (`animateBackground = false`) — it redraws every frame and pins the CPU.

## Swift 6 concurrency house style

- Target is Swift 6 strict concurrency. For objects that need a debounced
  main-thread hop (autosave), the pattern is
  `final class X: @unchecked Sendable` (documented main-thread-only) with
  `Task { @MainActor in … }` — **not** `@MainActor` classes with
  `nonisolated init` + `MainActor.assumeIsolated`, which cascades into
  "sending self" errors in the restore paths. This was tried; it fights back.
- App-global singletons follow `GitHubAuth`: `@MainActor @Observable final
  class` with `static let shared`.

## Persistence discipline

`StripPersistence` snapshots the live model into plain Codable DTOs.
Aliasing (shared content, shared workspaces) does not round-trip through
Codable — shared things are stored once and re-linked through their
registries on restore, in registry-first order. When you add model state:
add a DTO field (optional, so old saves still decode), snapshot it, restore
it, and force-quit-relaunch to prove it.

## Process rules

- **Experiment freely; merge carefully.** Branches are cheap — spike ideas,
  add throwaway UI, wire up diagnostics, keep whole experimental directions
  alive on their own branches (`swift/shared-buffer-experiments` is the
  pattern). What guards quality is the bar at `main`, not a ban on
  exploring.
- **`main` merges are feel-tested, not just build-tested.** This is a
  gesture app: before anything merges, it gets exercised on a real device
  for feel — gesture latency, spring weight, keyboard behavior, the gesture
  matrix around the change — and for function (including force-quit →
  relaunch when model state changed). "Builds and looks right in the
  simulator" is the start, not the bar.
- **What lands in `main` is clean.** Temporary NSLogs, auto-performed
  gestures, UI-test drivers, seeded fixtures — great while exploring, gone
  before merge. (A leftover auto-swipe once shipped a haunted onboarding
  ring.)
- **Show, don't just describe.** Anything visible gets a screenshot or short
  clip in the PR description (GitHub hosts them). Exploration artifacts
  worth keeping — mockups, direction studies — live in `sketches/`.
- **Measure performance on device.** One known trap: with the keyboard up,
  the iOS *simulator* runs a system-owned looping A/V pipeline (software
  H.264) inside the app process — ~10 %+ constant CPU that is not real;
  devices decode in hardware. Judge CPU with the keyboard down, or on
  device.
- **Docs move with behavior**: `swift/README.md` (gestures/functionality),
  `DESIGN.md` (look/motion), `ROADMAP.md` (scope changes).

## File map

| File | Owns |
|---|---|
| `MouseApp.swift` | App entry, floating-keyboard host, tap-outside dismiss, window minimums |
| `ContentView.swift` | Backdrop + foreground composition |
| `ForegroundView.swift` | The shell: lanes, dividers, all shell gestures, ring swipes, `CarouselLane`, `Panel` |
| `CarouselDeck.swift` | Ring model: lanes/reserve, container catalog, onboarding chain, per-ring viewport (open file, terminal, editor focus) |
| `Workspace.swift` | Project truth: tree on disk, dirty set, sync state, graph cache, tarball download, native tar/gzip (`TarGz`) |
| `WorkspaceViews.swift` | Files/Viewer containers, `FileBuffer` (shared live documents), action chips (push/pull) |
| `GitGraphView.swift` | Commit-graph layout + rendering, history fetch |
| `GitHubAuth.swift` | Device Flow, Keychain, sign-in container |
| `GitHubPush.swift` | Git Data API push (blobs → tree → commit → ref) |
| `Shell.swift` | `msh` — the from-scratch shell: lexer, pipes, redirects, globs, env, all built-ins |
| `Terminal.swift` | `TerminalSession` (engines: msh, js), JS engine, switcher chip, container, prompt field |
| `StripPersistence.swift` | Snapshot/restore DTOs for the whole strip |
| `AsciiArt*.swift`, `AppFont.swift` | Backdrop art, type constants |
