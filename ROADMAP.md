# Roadmap

Mouse's vision is bigger than an IDE: it's a gesture shell that absorbs the
jobs of whole desktop products, one product at a time. Each absorption is a
**product branch** — a long-running branch that asks one question:

> *What would X be if it had been born on a phone?*

A product branch is an exploration space: it can carry demo scaffolding,
half-ideas, and dead ends. Slices graduate to `main` when they're feel-tested
and clean (see [CONTRIBUTING.md](CONTRIBUTING.md)). Branches spawn when work
starts, not before — this page is the map of intended branches, in rough
order of attack.

## Platform stance

**Native per platform, no bridges.** Two apps sharing one spec and one
design language: `swift/` (iOS/iPadOS, the lead platform) and `kotlin/`
(Android, at feature parity — same shell, GitHub, workspaces, containers).
No web builds and no cross-platform
frameworks — the earlier Capacitor/web incarnation was removed deliberately
and is not coming back. Each platform gets the gesture shell built against
its own touch system, done properly — and each keeps its honest advantages
(Android apps may run the system shell; iOS gets the from-scratch `msh`).

## Product branches

### `vs-code` — the editor *(active today as `vs-code-features`)*

The IDE absorption: workspaces, file tree, in-place editor, commit graph,
terminal, push/pull. Largely shipped (see below). Still on this branch's
plate:

- **libgit2**: real clones, offline commits, branches, merges, full ref
  topology in the graph, honest conflict surfacing
- Editor upgrades: syntax highlighting + line numbers (Runestone/TextKit 2),
  find in file, font-size setting, large-file strategy
- Terminal engines: the package engine (`pnpm install`, lockfile-driven,
  reusing the native tar/gzip extractor) and dev-server engine
  (statically-linked esbuild, `dev`/`build`), LAN hosting, and a Preview
  container — projects you can *run*, not just edit
- More terminal engines behind the switcher: ssh, and `git`/`npm` becoming
  real commands inside `msh` as their engines land

### `cursor` — the AI pair

AI in the loop of editing: a chat container that knows the workspace, inline
edit proposals you accept by gesture, diffs as first-class containers.
The shell is already multi-view (rings share one live document), which is
exactly the substrate an AI collaborator needs.

### `cursor-agents` — the background workforce

Autonomous agents running against workspaces: kick off a task, swipe away,
come back to a diff. Agent runs as containers — their logs, their diffs,
their approval gates — with the ring as the review queue.

### `n8n` — automation

Workflows as a container kind: triggers, nodes, and connections built by
touch. The gesture shell's spatial model (rings of lanes) maps naturally
onto pipelines; the terminal and git engines become nodes.

### `figma` — design

A canvas container: vector shapes, frames, components, manipulated with the
same two-finger vocabulary the shell already teaches. Design artifacts live
in the workspace next to the code they describe.

### `xcode` — building for the platform

The self-hosting question: how much of building *apps for this phone* can
happen *on* the phone — Swift syntax support, project scaffolding,
previews, and whatever the platform's toolchain rules allow.

### `flutterflow` — visual app building

Compose real UI by direct manipulation, generate honest code into the
workspace. The inverse of the `figma` branch: not drawing pictures of apps,
assembling running ones.

## Foundations (serve every branch)

Cross-cutting work that lands on `main` directly and unblocks branches:

- **Cross-device sync**: the shared `FileBuffer` is one canonical document
  per file — promote it to a CRDT document when replicas span devices
  (deliberately deferred until then)
- Workspace storage management: sizes, eviction, "remove from device"
- Performance budget on device: rings scale without cost creep
- App Store path: TestFlight, accessibility pass, privacy manifest

## Shipped so far

The `vs-code` direction's first wave, all on `main`:

- Ring/lane/strip shell with the gesture law, self-teaching onboarding,
  full persistence
- GitHub Device Flow sign-in (Keychain), repo download via tarball API with
  a from-scratch native tar/gzip extractor
- Files tree; in-place editor (floating keyboard, autosave, shared live
  buffers across rings); commit graph
- `msh`, a from-scratch shell (quoting, variables, pipes, redirection,
  globs, `&&`/`||`, history, ~50 built-ins incl. `sed`/`diff`/`base64`/
  checksums) plus a JavaScriptCore engine, behind the terminal's switcher
- Real networking in the terminal: `ping` (unprivileged ICMP, streaming,
  any-keypress interrupt), `curl`/`wget` (URLSession), `sleep` — on the new
  async streaming-command machinery
- The Android app (`kotlin/`, Compose): feature parity with iOS — the
  gesture shell, onboarding, GitHub sign-in, workspaces (native tar/gzip),
  Files/Viewer/Graph, push/pull, persistence, and a terminal with both
  `msh` and the real system `sh` behind the switcher
- Push (Git Data API, one real commit) and pull with upstream detection
- iPad multitasking with an iPhone-sized minimum window

## Known gaps (tracked, not forgotten)

- Edge strips capture all drags in their 32 pt band — clearly-vertical drags
  there should yield to content scrolling
- The commits API returns default-branch history only (until libgit2)
- Identity registries (workspaces, buffers, synced content) never evict
- Ring-removal UX for rings other than the last lane's pinch
