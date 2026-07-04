# Swift

Blank native iOS app. Open `Mouse.xcodeproj` in Xcode and run.

```bash
open Mouse.xcodeproj
```

Generated from `project.yml` via [XcodeGen](https://github.com/yonaskolb/XcodeGen). Edit the YAML and run `xcodegen generate` to update the project.

## Functionality

The model lives in `Mouse/CarouselDeck.swift`, the interaction layer in `Mouse/ForegroundView.swift`.

- **Ring** (`CarouselDeck`) — a circular set of container instances. The screen is a window over it: on-screen instances sit in **lanes**, the rest in the ordered off-screen `reserve`. Swiping a lane pulls the next instance in from one shared edge and pushes the old one off the other, so instances shuffle freely between lanes.
- **Ring strip** (`RingStrip`) — an ordered list of rings; exactly one is on screen. Dragging from a screen-edge strip swipes the whole ring: to the neighbouring ring on that side, or — when the strip ends there — a freshly minted single-lane ring (container 1, rest of the catalog in reserve). A fresh ring only joins the strip if the swipe commits.
- **Container instance** (`ContainerType`) — one spot-holder on a ring, identified per-instance; a ring may hold several instances of the same catalog `kind`.
- **Container content** (`ContainerContent`) — what's inside, reference-typed and separate from the instance. Kinds in `ContainerContent.syncedKinds` resolve to a single app-wide object, so every instance of that kind, across all rings, shares (and live-updates from) the same state. Other kinds get private content per instance. To sync more kinds, add them to that set.
- **Persistence** (`Mouse/StripPersistence.swift`) — the whole strip (ring order, lanes and their heights, reserves, removed-lane history, shared content) is snapshotted to one atomic JSON file in Application Support whenever the app leaves the active scene phase, and restored at launch; first launch falls back to the demo ring. The live model is mirrored into plain Codable DTOs so the shared-content aliasing survives the round trip — extend `ContentSnapshot` as `ContainerContent` gains real fields.
