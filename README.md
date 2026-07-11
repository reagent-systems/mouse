# Mouse

**A coding IDE built for a phone — not shrunk from a desktop.**

Mouse is a native iOS app where an entire development environment lives in a
gesture-driven shell: you swipe between editors, pinch workspaces open and
closed, and edit files with the file itself, right in place. It talks to
GitHub directly — sign in, clone, edit, commit, push, pull — with no server,
no git binary, and no dependencies beyond the platform.

```
　C・プ
＼(　）
  ｀｀
```

## The interaction model

The screen is a window onto a **ring** of containers, split into horizontal
**lanes**. A strip of rings extends off both edges of the screen. One law
decides every input conflict between the shell and container content:

> **One-finger horizontal drags and all two-finger gestures belong to the
> shell, everywhere. Content gets taps, vertical scrolling, and the keyboard.**

| Gesture | What it does |
|---|---|
| Horizontal drag on a lane | Swipe to the next/previous container on the ring |
| Drag from a screen edge | Swipe the whole ring — travel between rings, or mint a new one |
| Drag a divider | Resize the two adjacent lanes |
| Two-finger spread / pinch | Open / close a lane; pinching the last lane closes the ring |
| Tap, vertical scroll, keyboard | The container's — trees scroll, editors edit, terminals type |

A ring holds one project (a **workspace**). Its containers are windows onto
that project: Files browses it, the Viewer edits its open file, the Graph
shows its history, the Terminal runs commands in it. Two rings on the same
repo share one workspace — same tree, same git state — but keep their own
open file and terminal, so swiping between rings is switching between editors
on the same project. Two rings on the same **file** share one live document:
keystrokes in one are instantly the other's content.

The full interaction and architecture reference lives in
[swift/README.md](swift/README.md).

## What works today

- **Onboarding ring** — the gestures teach themselves; motion is the arrow
- **GitHub sign-in** — OAuth Device Flow, tokens in the Keychain
- **Workspaces** — clone any of your repos via the tarball API, extracted by
  a from-scratch native tar/gzip reader
- **Files** — lazy tree, tap to open
- **Editor** — in-place editing with a floating keyboard that never shifts
  the app, debounced autosave, live shared buffers across rings
- **Commit graph** — branch rails, merges, tips, drawn like a desktop client
- **Terminal** — native command dispatcher (`ls`, `cat`, `grep`, `open`, …)
  scoped to the workspace
- **Push & pull** — corner action chips: one real commit via the Git Data
  API; pull with upstream detection
- **Persistence** — the whole strip survives force-quit and relaunch
- iPhone (portrait) and iPad (all orientations, iPhone-sized minimum window)

## Building

Requirements: macOS with **Xcode 16+** and **[xcodegen](https://github.com/yonaskolb/XcodeGen)**
(`brew install xcodegen`).

```sh
cd swift
xcodegen generate      # regenerates Mouse.xcodeproj from project.yml
open Mouse.xcodeproj   # build & run the Mouse scheme
```

Or headless:

```sh
xcodebuild -project swift/Mouse.xcodeproj -scheme Mouse \
  -destination 'generic/platform=iOS Simulator' build
```

The project file is generated — edit [swift/project.yml](swift/project.yml),
never the `.xcodeproj`, and re-run `xcodegen generate` after adding, removing,
or renaming source files.

## Repository layout

| Path | What it is |
|---|---|
| [swift/](swift/) | The app. `project.yml` is the project definition; `Mouse/` is all sources |
| [swift/README.md](swift/README.md) | Deep reference: gestures, containers, architecture |
| [DESIGN.md](DESIGN.md) | The design language — surfaces, type, motion, voice |
| [ROADMAP.md](ROADMAP.md) | The vision: product branches, each absorbing a desktop product |
| [CONTRIBUTING.md](CONTRIBUTING.md) | How to work on Mouse |
| [AGENTS.md](AGENTS.md) | The contract for AI agents (and a landmine map for humans) |
| [sketches/](sketches/) | Design history — screenshots of the idea finding its shape |

## Status & direction

Pre-release and moving fast. The shell, GitHub round-trip, and editing are
real and daily-drivable; git is still API-backed (libgit2 is next). The
larger vision is a gesture shell that absorbs the jobs of whole desktop
products — VS Code first (that's this branch), then Cursor, n8n, Figma, and
more — each developed on its own **product branch**. The map is in
[ROADMAP.md](ROADMAP.md).

Mouse is **iOS/iPadOS native only**, by decision: no Android port, no web
build, no cross-platform framework. Expect sharp edges.

## License

[MIT](LICENSE) © Reagent Systems and Mouse contributors.
