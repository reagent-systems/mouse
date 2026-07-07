# Swift

Blank native iOS app. Open `Mouse.xcodeproj` in Xcode and run.

```bash
open Mouse.xcodeproj
```

Generated from `project.yml` via [XcodeGen](https://github.com/yonaskolb/XcodeGen). Edit the YAML and run `xcodegen generate` to update the project.

## Gestures

One law decides every input conflict between the shell and container content:

> **One-finger horizontal drags and all two-finger gestures belong to the shell, everywhere. Content gets taps, vertical scrolling, and the keyboard.**

The shell's vocabulary (unchanged no matter what a container shows):

| Gesture | Owner | Meaning |
|---|---|---|
| One-finger horizontal drag on a lane | Shell | Swipe the lane to the next/previous container on the ring |
| One-finger drag from a screen-edge strip (32pt) | Shell | Swipe the whole ring — travel to a neighbouring ring, or mint a new one |
| One-finger vertical drag on a divider handle | Shell | Resize the two adjacent lanes |
| Two-finger spread / pinch | Shell | Open a new lane / close a lane |
| Tap, one-finger vertical drag inside a lane | Content | Whatever the container wants |

Per container:

- **GitHub** — taps only (buttons, tap-to-copy the device code).
- **Files** — vertical scroll moves through the tree; tap a folder to expand/collapse, tap a file to open it in the Viewer. Swiping the lane away works from anywhere on the tree, because the tree never claims horizontal drags.
- **Graph** — vertical scroll through the commit history; nothing else claims input yet (taps for commit detail later).
- **Viewer** — the open file, **edited in place**: tap the text and the caret lands under your finger, the keyboard rises, and you're editing right in the lane — no overlay, no mode. The spacebar-trackpad steers the caret; drag the text downward to dismiss the keyboard. Changes autosave (debounced ~0.8s) and flush on file switches and backgrounding. Lines wrap instead of panning horizontally (horizontal is the shell's), and text can't pinch-zoom (pinch is lane management) — font size will be a setting. The deck ignores the keyboard; the editor scrolls its caret into view within its own container. (A possible future refinement: stretch the editing container while the keyboard is up.)
- **Terminal** (planned) — tap to focus and raise the keyboard; typing goes to the prompt; spacebar-trackpad steers the cursor; scrollback is a vertical scroll; output wraps like a real terminal, so it never wants horizontal panning.

**How the law is enforced** (`CarouselLane.swipe`): scrollable content is UIScrollView-backed, and UIScrollView claims every drag that starts on it — so the lane swipe attaches as a *simultaneous* gesture (which scroll views can't block) and arbitrates itself: at first movement each drag locks to an axis, horizontal-dominant drags drive the lane while the gesture stands down entirely for vertical ones. Result: vertical scrolls content, horizontal swipes the lane, from anywhere on any container.

Other consequences the law creates: the keyboard shrinking the deck is shell behavior (lanes re-fit, same as divider changes); the edge strips must yield drags that are clearly vertical so tree-scrolls starting near the screen edge aren't eaten (known gap, to fix with the terminal phase); text-selection handle drags belong to UIKit's text interactions, which sit deeper than the lane gesture.

## Functionality

The model lives in `Mouse/CarouselDeck.swift`, the interaction layer in `Mouse/ForegroundView.swift`.

- **Ring** (`CarouselDeck`) — a circular set of container instances. The screen is a window over it: on-screen instances sit in **lanes**, the rest in the ordered off-screen `reserve`. Swiping a lane pulls the next instance in from one shared edge and pushes the old one off the other, so instances shuffle freely between lanes.
- **Ring strip** (`RingStrip`) — an ordered list of rings; exactly one is on screen. Dragging from a screen-edge strip swipes the whole ring: to the neighbouring ring on that side, or — when the strip ends there — a freshly minted single-lane ring (container 1, rest of the catalog in reserve). A fresh ring only joins the strip if the swipe commits.
- **Container instance** (`ContainerType`) — one spot-holder on a ring, identified per-instance; a ring may hold several instances of the same catalog `kind`.
- **Container content** (`ContainerContent`) — what's inside, reference-typed and separate from the instance. Kinds in `ContainerContent.syncedKinds` resolve to a single app-wide object, so every instance of that kind, across all rings, shares (and live-updates from) the same state. Other kinds get private content per instance. To sync more kinds, add them to that set.
- **Onboarding ring** (`CarouselDeck.onboarding()`, preset kinds ≤ 0) — first launch opens a dedicated, isolated ring of lesson containers (blank fillers + one lesson at a time; empty reserve, so nothing else swipes). No arrows anywhere: each lesson's `idle` animation suggests its gesture, and the label flips to past tense live, mid-gesture, via the content's `done` flag. The chain: **Swipe?** (horizontal bounce; "Swiped." past the commit threshold; retires once swiped, handing its lane to) → **Drag?** (label rides the divider gap; gap-reach idle — both sides of the gap move the SAME direction via the deck's shared `dragPulse`, so the boundary itself visibly travels up and back; "Dragged." mid-drag, then morphs into) → **Spread?** (same gap label; gap-breathe idle — both sides retreat in OPPOSITE directions via the shared `spreadPulse`, widening the space as a bounce; the two-finger spread opens a new lane, which arrives blank and only takes on) → **Pinch?** (after "Spread." has left the stage; shrink pulse; flips to "Pinched." and removes itself when pinched closed) → **Edge Swipe?** (rotated label in the ring's right gutter — rendered inside the stack, so it gets dragged along with the ring as the user swipes it away; "Edge Swiped." mid-drag). The drag lesson's word rides its boundary pulse; the spread word holds still while its gap breathes. Lessons appear strictly one at a time — the edge lesson waits until no lesson container is in the lanes at all — and gap labels live outside the container, so idle animations never move them. Every lesson word uses the same type (IBM Plex Mono, 28pt, black when outside a container); the layout makes room for the words rather than shrinking them: dividers grow to `lessonDividerHeight` while a gap-label lesson is up (lanes re-fit automatically), and the side gutters widen during the edge lesson to fit the rotated label. The edge swipe creates the user's first real ring, and the onboarding ring retires behind them once the transition settles. All lesson states persist (`done` in `InstanceSnapshot`, `isOnboarding` in `RingSnapshot`); a lesson saved mid-morph restores as its successor.
- **GitHub container** (`Mouse/GitHubAuth.swift`, catalog kind 1) — the first real container: sign in with GitHub via the OAuth Device Flow, using the same public GitHub App client id as the web client (`src/auth/GitHubAuth.ts`), so one GitHub App serves every Mouse frontend. The container shows a code to enter at github.com/login/device (tap to copy, button to open), polls until authorized, then shows `@login`. Tokens (access + refresh) live in the Keychain; the login handle is cached for instant restore and the session re-validates in the background (refresh-once on 401, sign-out if that fails, offline keeps the cached session). Sign-in state is app-global — every instance of the GitHub container in any ring reflects the same session.
- **Workspace** (`Mouse/Workspace.swift`, `Mouse/WorkspaceViews.swift`) — a ring's project: a working tree on local disk plus cross-container state. The **Files container** (kind 2) lists the signed-in user's repos, downloads one via GitHub's tarball API (native gunzip + tar extraction — ustar/GNU-longname/pax, shared infrastructure for the future package manager), and browses the tree (vertical scroll, tap folders to expand, tap a file to open). The **Viewer container** (kind 3) shows the workspace's open file: mono, line numbers, wrapped lines (no horizontal panning per the gesture law), read-only for now. Ring ↔ workspace association and the open file persist; a missing tree falls back to the repo picker. Real containers (GitHub/Files/Viewer) render black, terminal-styled. libgit2 (real clones, status, commits) arrives with the Source Control phase.
- **Graph container** (`Mouse/GitGraphView.swift`, kind 4) — the workspace's commit graph: colored branch rails with lane assignment computed from parent topology (newest-first; a commit lands on the rail expecting it, other expecting rails curve in and close, merge parents fan out or connect to existing rails), filled dots for commits, rings for merges, branch tips as capsule labels. History comes from the GitHub API for now; libgit2 swaps in as the data source later without changing the layout or view. Vertical scroll only.
- **Persistence** (`Mouse/StripPersistence.swift`) — the whole strip (ring order, lanes and their heights, reserves, removed-lane history, shared content) is snapshotted to one atomic JSON file in Application Support whenever the app leaves the active scene phase, and restored at launch; first launch falls back to the demo ring. The live model is mirrored into plain Codable DTOs so the shared-content aliasing survives the round trip — extend `ContentSnapshot` as `ContainerContent` gains real fields.
