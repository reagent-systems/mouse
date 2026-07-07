# Branch: `vs-code-features`

How Mouse's containers went from colored placeholders to a working, GitHub-connected IDE:
sign-in, repo workspaces, a file tree, an in-place editor, a commit graph, a terminal, and
commit/pull round-trips — all native Swift, no git binary, no server.

The organizing idea throughout: **a ring is a workspace**. Each ring holds one project
(`Workspace`), and its containers are windows onto that one project — Files browses it, the
Viewer edits its open file, the Graph shows its history, the Terminal runs commands in it, and
the corner action chips move it to and from GitHub.

---

## Commits

| Commit | What landed |
|---|---|
| `73ff3dd` | **GitHub sign-in container** (kind 1): OAuth Device Flow, Keychain tokens, app-global session |
| `891c81e` | **Workspace + Files + Viewer**: ring↔workspace model, tarball download + native tar/gzip, file tree, read-only viewer |
| `630dfdb` | **Graph container** (kind 4) + iPad orientation/multitasking support |
| `e6bb111` | **Container-identity rendering** (no unload flash on swipe) + axis-locked gesture arbitration |
| `f7363d3` | **Floating keyboard** (never shifts the app) + **in-place editing** with autosave |
| *working tree* | **Action chips** (push ∧ / pull ∨ with upstream detection), **Terminal container** (kind 5), pinch-removes-ring, view-tracking bugfix |

---

## 1. GitHub container (kind 1) — `Mouse/GitHubAuth.swift`

The identity layer everything else authenticates through.

- **OAuth Device Flow** against the same public GitHub App client id the web client ships
  (`src/auth/GitHubAuth.ts`), so one GitHub App serves every Mouse frontend. No client secret
  exists in the app; the flow is: request device code → show it big in the container (tap to
  copy) → user enters it at github.com/login/device → poll `access_token` respecting
  `interval`/`slow_down` → store.
- **Storage**: access + refresh tokens in the **Keychain** (`kSecClassGenericPassword`); only
  the non-secret login handle is cached in UserDefaults for instant restore at launch.
- **Session lifecycle**: on launch, the cached session shows immediately and re-validates in
  the background — a 401 triggers one refresh-token attempt, failure signs out, network errors
  keep the cached session (offline never logs you out).
- **Global by design**: `GitHubAuth.shared` is one `@Observable` object, so every instance of
  container 1 in any ring shows the same session live.

## 2. Workspace — `Mouse/Workspace.swift`

The ring's project. Holds the local tree location, cross-container state, and sync state:

- `root` — the working tree on disk, at `Documents/workspaces/owner__name/` inside the app
  sandbox (device-local, in iCloud/device backups, deleted with the app, invisible to other
  apps until we opt into Files-app exposure).
- `openFilePath` — the cross-container channel: Files sets it, the Viewer shows it, the
  terminal's `open` command sets it too.
- `modifiedPaths` — relative paths edited since the last successful push (persisted). Fed by
  the editor's autosave and file-creating terminal commands. Drives the push chip.
- `syncedSha` / `upstreamAvailable` — the remote head sha the tree was last synced to
  (download, pull, or our own push), and whether the live remote differs. Drives the pull chip.
  Checked at most once a minute, only while an action row is on screen.
- `treeVersion` — bumped when the tree is replaced wholesale (a pull); file views key their
  reload tasks on it.
- `terminal` — the ring's `TerminalSession` (scrollback + cwd live with the project).
- `phase` — downloading / ready / failed, driving the Files container's states.

**Acquisition** is GitHub's tarball API + a from-scratch native extractor (`TarGz`):
gzip header parsed by hand, raw-DEFLATE inflate via the Compression framework, tar parsed by
hand (ustar + GNU longname + pax `path` records — verified against real GitHub tarballs and
pax fixtures with >100-char paths, symlinks, empty dirs). No libgit2 yet — it arrives with the
Source Control phase and replaces acquisition without changing this model's shape. The
extractor is shared infrastructure: `pnpm install` will use the same code path on registry
tarballs.

## 3. Files container (kind 2) — `Mouse/WorkspaceViews.swift`

- No workspace → **repo picker**: the signed-in user's repos (`GET /user/repos`, private
  included), tap to download.
- Downloading / failed → progress and retry states.
- Ready → **lazy file tree**: directories read from disk on expand, dirs-first sorting, `.git`
  hidden, tap a file to open it in the Viewer (sets `openFilePath`), open file highlighted.
- All interaction is taps + vertical scroll per the gesture law; lane swipes work from anywhere
  on the tree.

## 4. Viewer container (kind 3) — in-place editor

The open file, **edited right in the lane** — no overlay, no mode:

- Tap the text → caret lands under your finger, keyboard rises (see §8 for why the app doesn't
  move). iOS's spacebar-trackpad steers the caret. Drag the text down to dismiss the keyboard
  interactively.
- **Autosave**: debounced 0.8s after the last keystroke; immediate flush on file switch and on
  backgrounding. Each flush marks the file in `modifiedPaths` (surfacing the push chip).
- A `suppressNextChange` flag distinguishes programmatic loads from user edits — *viewing* a
  file must never mark it modified (this was a live bug: opening a file used to queue an
  identical-bytes save that flagged it for commit).
- Guards: binaries and >1.5MB files show a note instead of an editor. Lines wrap (no horizontal
  panning — that's the shell's axis).

## 5. Graph container (kind 4) — `Mouse/GitGraphView.swift`

The commit graph, drawn like a desktop git client:

- **Data**: GitHub API (`/commits?per_page=80` + `/branches`) — no `.git` needed. When libgit2
  lands, only this data source changes.
- **Layout**: classic lane assignment, newest first. Each rail carries the sha it expects next;
  a commit lands on the first rail expecting it; other expecting rails curve in and close
  (branch points); the first parent inherits the rail; extra parents (merges) connect to
  existing rails or open new ones. Verified headlessly against branch/merge and stacked-merge
  topologies (9 assertions).
- **Rendering**: per-row `Canvas` — pass-through verticals, quad-curve joins/fans, filled dots
  for commits, stroked rings for merges, colored rails cycling an 8-color palette, branch tips
  as capsule labels, message + short-sha + author beside each row.
- Reloads on `treeVersion` (after pulls). Honest limit: the commits API returns default-branch
  history, so merged branches show as rails but unmerged side branches won't appear until
  libgit2 provides full ref topology.

## 6. Terminal container (kind 5) — `Mouse/Terminal.swift`

A native command dispatcher with a real terminal's look (the a-Shell model — iOS has no
fork/exec, so commands are Swift implementations against the workspace):

- **Session** (`TerminalSession`): scrollback (500-line cap), `cwd`, prompt (`~/src $`). Lives
  on the `Workspace`, so it survives swiping away and back.
- **Built-ins**: `ls cd pwd cat echo mkdir touch rm [-r] mv cp head tail [-n N] find grep`,
  `clear`, `help`, and `open <file>` — the first cross-container command (routes a file to the
  Viewer). Path resolution is cwd-relative with `/` meaning the workspace root and `..` clamped
  at the root — the workspace cannot be escaped.
- File-creating commands (`touch`, `cp`, `mv`) mark their outputs modified, so terminal-made
  files ride the push flow.
- `git` / `npm` / `pnpm` / `node` / `npx` answer honestly that their engines are still on the
  roadmap (libgit2 and the native package/dev-server engines).
- **Prompt field**: a UIKit `UITextField` representable whose delegate returns `false` from
  `textFieldShouldReturn` — the command runs and the keyboard **never dips** between commands
  (SwiftUI's `TextField` unavoidably dismisses on submit).
- **Scrollback**: a bottom-anchored `ScrollView` (`defaultScrollAnchor(.bottom)`) — output
  sticks to the bottom using real layout (manual `scrollTo` miscalculated against unlaid-out
  wrapped lines and parked responses offscreen), and scrolling up to read history holds.

## 7. Container actions — `ContainerActionsRow` + `Mouse/GitHubPush.swift`

A horizontal stack of small round chips (22pt, hand-drawn `/\` and `\/` Path glyphs) in every
real container's top-right corner. **Each chip appears only when its prerequisites are met**,
so the stack is itself a status display:

- **Push (∧)** — appears when `modifiedPaths` is non-empty and a session exists. Tap → commit
  message prompt (sensible default) → one **real commit** via the Git Data API with no `.git`
  directory: upload a blob per edited file → create a tree **based on the remote's current
  tree** (untouched files preserved even if the remote moved) → create the commit with the
  branch head as parent → fast-forward the ref. On success the dirty set clears and
  `syncedSha` records our own commit (so it doesn't read as upstream news). Honest limit:
  last-write-wins on exactly the paths we edited; real merges arrive with libgit2.
- **Pull (∨)** — appears only when `upstreamAvailable` (remote head ≠ `syncedSha`). Warns
  destructively if unpushed edits would be discarded, re-downloads the tarball, bumps
  `treeVersion` so the Viewer and Graph reload.
- Busy chips show a spinner; failures turn the glyph red and surface the reason in the next
  prompt.

## 8. The keyboard architecture — `Mouse/MouseApp.swift`

The hardest-won piece of the branch. Requirement: the keyboard floats **in front** of the app
(YouTube-style) and never shifts or resizes the lanes.

- **Why naive fixes fail**: the deck is sized by `containerRelativeFrame`, which measures the
  *window container* — and normal hosting shrinks that container for the keyboard at the
  source. No SwiftUI-side `ignoresSafeArea(.keyboard)` can reach it (we proved this twice),
  and swapping to `GeometryReader` broke lane layout (the ascii-background sibling inflates
  ZStack geometry — a failure mode the code comments had warned about).
- **The fix**: `KeyboardFloatingHost` — a bridged `UIHostingController` with
  `safeAreaRegions = .container`, excluding the keyboard region from safe areas *at the
  hosting level*, upstream of everything. Container safe areas (status bar, home indicator)
  still apply. The deck's layout code is untouched.
- **Tap-to-dismiss**: a window-level `UITapGestureRecognizer` (non-cancelling, so the tapped
  thing still gets its tap) dismisses the keyboard on any tap outside a text input; taps
  *inside* text inputs are filtered so caret placement never fights dismissal; the keyboard's
  own window never reaches the recognizer.
- Consequence accepted by design: nothing insets for the keyboard, so it genuinely covers
  whatever is under it (editing a bottom lane means the editor is partially covered until you
  scroll or resize). The contained future fix is a bottom content-inset on just the text view.

## 9. Shell integration

Changes to the ring/lane system this branch needed:

- **Container-identity rendering** (`e6bb111`): the visible panel trio (left edge / current /
  right edge) renders through a `ForEach` keyed on **container id** with one uniform modifier
  chain — a swipe commit moves the same view instances to new offsets instead of rebuilding
  them, so loaded state (tree, file, graph) survives and nothing flashes at release.
- **Axis-locked lane swipes** (`e6bb111`): UIScrollView-backed content claims every drag, so
  the lane swipe attaches as a *simultaneous* gesture and arbitrates itself — each drag locks
  to an axis at first movement; horizontal drives the lane, vertical stands down for content
  scrolling. Works from anywhere on any container.
- **Pinch removes rings** (working tree): pinching the *last* lane closes the whole ring,
  landing on the left neighbour; closing the final ring replaces it with a fresh one — the
  strip can never be empty. The inward counterpart to edge swipes creating rings outward. The
  onboarding ring is exempt. Workspace trees stay on disk, so a removed ring's repo reopens
  instantly.
- **Persistence additions** (`Mouse/StripPersistence.swift`): per-ring `workspaceRepo`,
  `openFile`, `workspaceDirty`, `workspaceSyncedSha` — all optional fields, backward-compatible
  with older snapshots. A restored ring reattaches its workspace if the tree is still on disk,
  or falls back to the repo picker.

## 10. File map

| File | Role |
|---|---|
| `Mouse/GitHubAuth.swift` | Device Flow, Keychain, session lifecycle, sign-in container UI |
| `Mouse/Workspace.swift` | Workspace model, tarball fetch, `TarGz` extractor, repo listing, upstream detection |
| `Mouse/WorkspaceViews.swift` | Repo picker, file tree, in-place editor, `ContainerActionsRow`, chevron glyphs |
| `Mouse/GitGraphView.swift` | History fetch, lane-layout algorithm, Canvas graph rendering |
| `Mouse/Terminal.swift` | `TerminalSession` dispatcher, built-ins, terminal UI, keep-focus prompt field |
| `Mouse/GitHubPush.swift` | Git Data API commit (blobs → tree → commit → ref) |
| `Mouse/MouseApp.swift` | `KeyboardFloatingHost`, tap-to-dismiss, iPad window minimum |
| `Mouse/CarouselDeck.swift` | Container kinds/catalog, ring model (pre-existing, extended) |
| `Mouse/ForegroundView.swift` | Shell: lanes, gestures, Panel routing, ring removal (pre-existing, extended) |
| `Mouse/StripPersistence.swift` | Snapshot DTOs incl. workspace fields (pre-existing, extended) |

## 11. Known limits / next hooks

- **No real merges**: push is last-write-wins on edited paths; pull replaces the tree. libgit2
  is the designated successor for acquisition, status, merge, and full ref topology.
- **Upstream check** is on-screen-and-throttled (≤1/min), not background polling.
- **Editor** is plain mono — syntax colors + line numbers return with the Runestone step.
- **Terminal** lacks pipes/redirection/quoting (parser work, not platform work), and `git`/
  `pnpm` await their engines: lockfile-driven installs (reusing `TarGz`), then the esbuild
  static-link spike for `pnpm dev`/`build` with LAN serving.
- **Deleted files don't push** (the Git Data API path skips missing files; deletion entries
  are a small addition when needed).
