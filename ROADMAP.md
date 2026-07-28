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

- **Git, merges**: the local engine, the remote half, AND native merges are
  BUILT (`GitCore` + `GitRemote`: clone/fetch/push over smart-HTTP, packfiles
  with delta resolution, push that auto-creates the GitHub repo via
  `POST /user/repos`, and a three-way merge engine — fast-forward /
  merge-commit / diff3 conflict markers — verified against `git merge-file`
  and a real repo). The git module toolbar (`commit · sync · branch · merge
  · refresh` in the Graph header) drives them; `sync` pushes, and pulling is
  the explicit `git pull` in the terminal (incremental fetch into the
  tracking ref + native merge — the app never rewrites a user's files on
  its own). Remaining: a `git clone` entry in the project picker
- Editor upgrades: syntax highlighting + line numbers (Runestone/TextKit 2),
  find in file, font-size setting, large-file strategy
- Terminal engines: the package engine (`pnpm install`, lockfile-driven,
  reusing the native tar/gzip extractor) and dev-server engine
  (esbuild-wasm/SWC-wasm, or native-ESM serving — **not** statically-linked
  esbuild, which is a Go binary and cannot exec on iOS), LAN hosting, and a
  Preview container — projects you can *run*, not just edit
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

**Full build plan: [xcode.md](xcode.md).** The short version: signing and
installing are ours to build (a from-scratch Mach-O signer + CMS envelope,
using the user's own Apple-issued certificate, key held in the Keychain);
compiling is the wall, so the working loop routes compilation through a CI
Mac and signs the artifact on device. The plan's Phase 0 (a local artifact
server) is the same server the dev-server engine and Preview container
need, so it pays for itself three times.

### `flutterflow` — visual app building

Compose real UI by direct manipulation, generate honest code into the
workspace. The inverse of the `figma` branch: not drawing pictures of apps,
assembling running ones.

### OpenShip Integration

### Visual Intelligence

### tl-draw


### `system` — running and compiling code on the device

The substrate the terminal, the Preview container, and the `xcode` branch
all stand on: **processes, `$PATH`, packages, and Mouse as their kernel.**

**Entry point: [system.md](system.md)** (the umbrella spec — platform
physics, execution substrates, Mouse-as-kernel, the Node compatibility
layer, and the unified phase map across every plan doc). Language-by-
language detail: **[compile.md](compile.md)**. The short version: iOS grants
exactly one JIT — WebKit's — so a `WKWebView` used as a compute engine is
the fastest execution surface available to Mouse, and the JavaScript/wasm
toolchain runs there at full speed (Mouse's current in-process `JSContext`
is interpreter-only, 10–30× slower). An in-app wasm runtime then gives real
processes and `$PATH`; a package manager reuses the existing tar/gzip and
HTTP; clang-wasm compiles C on device; and everything LLVM-sized (Rust, Go,
Swift) routes through CI and runs its artifact here. Compiling on device is
a *substrate* question, not a per-language one — which is why
[xcode.md](xcode.md)'s on-device compilation path is blocked on this branch.

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

- The native git engine (`GitCore` + `GitRemote`, from scratch like
  tar/gzip/ICMP/msh): loose objects, trees, commits, refs, branch/checkout,
  status, log, DIRC index — plus the remote half: packfiles (write + read
  with delta resolution), pkt-line, and clone/fetch/push over GitHub
  smart-HTTP. `git push` **creates the GitHub repo for you** (`POST
  /user/repos`) so you never make an empty repo first. Verified against the
  real git CLI both directions (fsck, index-pack, pack-objects,
  receive-pack). Local projects are born with `.git`; the Graph renders
  local history offline

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
