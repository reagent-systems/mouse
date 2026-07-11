# Mouse — Design Language

The source of truth for how Mouse looks, moves, and speaks. The interaction
model itself (rings, lanes, the gesture law) is specified in
[swift/README.md](swift/README.md); this document is about everything you
see and feel.

## 1. Principles

- **Mobile-first, one-handed.** Designed for a phone held in one hand;
  every control reachable, every gesture performable with a thumb. iPad is
  a bigger window, not a different app.
- **Motion is the arrow.** Nothing points, pulses a tutorial overlay, or
  draws a coach mark. When the UI wants to teach a gesture, it *performs a
  hint of the gesture*: the swipe lesson nudges sideways, the pinch lesson
  breathes smaller. Idle animations are the entire onboarding vocabulary.
- **Terminal honesty.** The visual language is a terminal's: monospace
  everything, black panels, text that states facts. Errors say what
  happened and why — never "something went wrong", never reassurance copy.
- **The container is the chrome.** No toolbars, no tab bars, no navigation
  stacks. Every capability lives inside a container or on its surface
  (corner chips), and the shell's gestures are the only navigation.
- **Calm, physical motion.** Springs everywhere, sized to feel like the
  surfaces have mass. Nothing teleports; things that leave slide or settle.

## 2. Surfaces

| Token | Value | Used for |
|---|---|---|
| Canvas | pure white | The app background |
| Backdrop art | near-white tints `#F4F6FA` / `#FAF5F6` | The ASCII logo behind everything (static; its animation is intentionally off — it costs a frame loop) |
| Container | pure black, corner radius **32 pt continuous** | Every real container |
| Lesson container | black with a `white @ 0.35` 1 pt inner stroke | Onboarding presets — outlined reads as instructional, filled reads as content |
| Side gutters | **24 pt** | Between containers and screen edges (widens to 40 pt during the edge lesson) |
| Container padding | **16 pt** | Content inset inside a container |
| Divider gap | **32 pt** tall, capsule handle 40 × 5 `secondary @ 0.45` | Between lanes; grows to 48 pt when a lesson word needs the gap |

Depth comes from geometry (black on white, big radii), never from shadows,
blurs, or gradients on surfaces.

## 3. Type

One family: **IBM Plex Mono Bold** (`AppFont.asciiName`), everywhere — UI,
editor, terminal, lesson words. No second typeface, no weights ladder.

| Size | Role |
|---|---|
| 28 | Lesson words ("Swipe?", "Edge Swipe?") — uniform across all lessons |
| 14 | Empty-state prompts |
| 13 | Body text in containers (graph rows, notes) |
| 12 | Editor text, terminal |
| 11 | Metadata (container headers like `owner/repo — history`) |

Line height is 1.2× fixed (`asciiParagraphStyle`). Editor and terminal text
**wraps** — horizontal panning belongs to the shell, so content never wants
it.

## 4. Color

Mouse is monochrome with one sanctioned exception.

- Text on black: white at **1.0** (content), **0.85** (secondary content),
  **0.6 / 0.55** (metadata, prompts, disabled).
- Text on white (lesson words outside containers): pure black.
- **The exception:** the commit graph's branch rails cycle an 8-color
  palette (orange, pink, cyan, green, purple, yellow, blue, red) — data
  encoding, not decoration.
- Red additionally marks failure states (a failed push chip). Nothing else
  is colored. There is no accent color; if a design wants one, the design
  isn't finished.

## 5. Motion

All motion is springs; durations are feel-tested, not standardized away.

| Spring | Where |
|---|---|
| `.snappy(0.2 – 0.25)` | Gesture settles: lane-swipe commit/return, ring swipe |
| `.spring(response: 0.4, dampingFraction: 0.82)` | Structure changes: lane add/remove, divider re-fit, gutter changes |
| `.spring(duration: 0.3 – 0.4)` | Idle-animation beats |

Rules:

- **One transaction per change.** When a structural change has two halves
  (divider grows, lanes shrink to compensate), both animate in the same
  `withAnimation` so totals never visibly waver.
- **Idle cadence:** ~1.4–1.6 s dwell, a two-beat hint (~0.4 s out, ~0.45 s
  hold, ~0.35 s home). Idle animations stand down instantly when a real
  gesture starts, and stop for good once their lesson is done.
- **Commit trick:** on a swipe commit the model mutates immediately and the
  view re-renders at the displaced offset, then glides to rest — what's on
  screen is never stale, and out-swiping the animation can't reveal seams.
- Values that ride gestures animate via `Animatable` machinery
  (`GeometryEffect`, scale effects) — parallel `.offset` + `.animation(value:)`
  combos desync on the first cycle.

## 6. Components

- **Action chips** (container top-right): 22 pt circles, white-on-black
  inverted, sitting *concentric* with the container corner — chip inset is
  chosen so `chip radius = corner radius − inset`. Glyphs are hand-drawn
  strokes (`ChevronGlyph`: ∧ push, ∨ pull), matching the ASCII language —
  no SF Symbols on container surfaces. A chip exists only while its
  prerequisites are met; a failed action turns its chip red and the next
  tap explains why in plain words.
- **Lesson words** ride the gesture they teach: the label flips to past
  tense ("Swipe?" → "Swiped.") the moment the gesture crosses its commit
  threshold — feedback lands mid-gesture, not after.
- **The keyboard floats.** It overlays the app (YouTube-style) and never
  compresses or shifts the layout; the focused editor scrolls its own caret
  into view. Tap anywhere outside text to dismiss. The terminal's keyboard
  stays up between commands.

## 7. Voice

- Lowercase, terminal-flavored, factual: `sign in with the GitHub container
  first`, `command not found: pnpm (type help)`.
- State the reason, not an apology: `file is too large to view (2048 KB)`.
- Unbuilt things say so honestly: `git: not built yet — the native git
  engine is on the roadmap`.
- No exclamation points, no "oops", no celebration copy.

## 8. Adding a container

A new container kind must answer, before any code:

1. What does it show at rest, in a lane that might be 80 pt tall?
2. Which taps and vertical scrolls does it claim? (It gets nothing else —
   the gesture law is not negotiable per-container.)
3. What are its corner-chip actions and their prerequisites?
4. What does it look like with no workspace, no sign-in, no network?
   (Every existing container has an honest empty state; yours does too.)
