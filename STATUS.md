# STATUS.md — the verified state of Mouse

Last reconciled: 2026-07-31, at commit 953dd98 (end of the phase-G run,
27ed75b..953dd98, 184 commits). This file is the one place that says where
every phase stands, with the evidence named. When a phase's state changes,
this file moves with it — same rule as every other doc here.

The letter phases are subsystems, not a sequence. Build order was
dependency-driven: T → A → F → G, with D falling out of G. compile.md
numbers some of the same ground differently; the mapping is noted per row.

## Phase map

| Phase | What it is | State | Evidence |
|---|---|---|---|
| **T** — terminal screen | VT100/xterm grid, ANSI parser, TUI hosting, keyboard encoding | **Done** | `swift/Mouse/TerminalScreen.swift`, `TerminalWidth.swift`, `TerminalPrograms.swift`. Gated: screen corpus, pyte cross-check, wide-char/alt-screen/DECCKM/bracketed-paste harnesses (`verify/tty`, `altscreen`, `widetui`, `inkwide`) |
| **A** — shell language | msh's POSIX-subset grammar: control flow, `$()`, functions, redirects | **Done** | `swift/Mouse/ShellLanguage.swift`. Gated against real `/bin/sh` on the 25-script corpus (`verify/shell`) |
| **F** — package manager | Real npm registry, semver, integrity, lockfiles; `npm run`/`create`/`npx`; native-binary → wasm-build substitution | **Done** | `swift/Mouse/PackageManager.swift`. Gated: semver corpus vs pnpm, `verify/pkg`, `firstrun` (scaffold→install→dev end to end) |
| **G** — the Node layer | Node 22-surface runtime on JavaScriptCore: modules, streams, fs, net/http/1.1+2, crypto, workers, child processes, vm, WASI | **Done** (this run) | `swift/Mouse/NodeEngine.swift` + `NodeSockets`/`NodeWatch`/`NodeKeys`/`NodeScrypt`/`NodeBrotli`/`NodeDNS`. ~88-gate suite green at 953dd98 (`verify/`), fixtures byte-identical to real node v22 |
| **D** — web toolchain | tsc, bundlers, dev servers | **Largely done**, as a byproduct of G | tsc + `tsc --watch`, webpack, esbuild-wasm, vite dev (HMR) and vite build (rollup-wasm) all gated (`verify/esbuild`, `devserver`, `hmr`, `firstrun`). Remaining piece is the Preview surface (phase C) |
| **B** — WebView JIT | Move JS/wasm execution into WKWebView for JIT speed | **Not started — optional** | Measured: everything runs interpreted; the JIT buys speed, not capability (system.md:2094). No longer a prerequisite for anything |
| **C** — Preview container | In-app viewing surface for what dev servers serve; LAN hosting | **Not started** | The server half works (vite serves clients outside the app — gated in `verify/devserver`); no in-app viewer exists |
| **E** — wasm runtime processes | Real processes: `$PATH`, executable bits, `ps`/`kill`/`&`, pipes between programs; other languages (Python first) as wasm32-wasi artifacts | **Runtime half done** | `pkg install python` downloads the official CPython wasm32-wasi build, hash-checks it, unpacks it (zip reader written here — iOS has no `unzip`) and `python hello.py` runs CPython 3.14.6. `swift/Mouse/Runtimes.swift` + mounts in `NodeEngine`. Gated: `verify/python`, `verify/pkgpython`. Written up in system.md §5b. Missing: `$PATH`, executable bits, background jobs (`&` is still refused by name in the lexer) |

## On the device

Headless evidence is no longer the only kind. The app builds, installs,
launches and is driven on the iPhone 16 Pro simulator
(`58A6B442-292A-4610-9DE8-500E7E8EBC74`). Confirmed there, not inferred:

- The terminal container runs `npm install left-pad` against the real
  registry and prints `added 1 packages`; `node -e` prints multi-line
  output, wrapped. An install is asynchronous — read the screen *after* it
  returns, not the instant Enter is pressed. That timing mistake was
  recorded here for a whole iteration as a rendering bug; it was not one.
- `npx n8n` resolves, downloads, installs and executes n8n's own bin on the
  phone. Three walls found there, all ours, all now fixed: the engine
  reported `v20.19.0` while every fixture in `verify/` is diffed against
  real node v22.22.3, so n8n's `engines: >=22.22` gate refused to start;
  `node -p` was unimplemented and answered `can't read -p`; and
  `util.inspect.defaultOptions` did not exist, which is line 31 of n8n's
  bin. Chasing that last one found a bigger gap behind it — the
  `[util.inspect.custom]` hook was never called at all, so every type with
  an opinion about how it prints was printing its raw fields instead.
  Gated in `verify/inspectopts` and `verify/nodeprint`.
- **Python runs on the phone.** `pkg install python` prints `fetching
  python 3.14.6 (14 MB)` / `installed python 3.14.6`; `python -c` prints
  `python 3.14.6 on wasi` and `{"squares": [0, 1, 4, 9, 16, 25]}`; and
  `python hello.py` prints what the script prints. Screenshots at 23:48 on
  2026-07-31.
- **A node server runs on the phone and answers real requests from off the
  device.** `node server.js` printed `listening on 8787`, and three
  requests made from the Mac (`GET /hello-from-the-mac`, `GET /page-two`,
  `POST /submit`) were each logged live in the terminal as they arrived;
  curl received `HTTP/1.1 200` and the body. The simulator shares the
  host's network stack, so those were real external requests, not a
  loopback inside the app.
- **A running program could not be stopped at all**, found by doing the
  above: while a full-screen program owns the keyboard every keystroke is
  routed to it, so the any-key interrupt beneath it can never fire — and an
  iOS keyboard has no Control key. A `node` server held the terminal until
  the app was killed. There is now a `^C` chip beside the prompt, shown
  only while a program runs; tapping it sends the interrupt the program
  already knew how to handle. Verified: the server stopped, the prompt came
  back, and the port stopped answering.
- Navigation is the gesture law working as designed: an in-lane horizontal
  drag cycles containers within a ring, an edge drag travels between rings
  **or mints a new one**. The "Swipe?" screen is the onboarding lesson
  chain (`CarouselDeck.onboarding()`), not a failure state; it exits by
  edge swipe.

## What runs today (all gated, none aspirational)

Real packages through the engine's own installer: claude-code 1.0.128's UI,
ink/React TUIs, jest, mocha, eslint, tsc, prettier, vite, webpack, esbuild,
express, fastify, gRPC, axios, the Anthropic SDK with token streaming,
jsonwebtoken on all four JWT algorithms, tar, archiver, chokidar. The shell
runs POSIX scripts verified against `/bin/sh`; git, npm, node are real msh
commands.

## Known walls (each refuses with its reason)

- **Native code**: no exec, no `.node` addons, no downloaded binaries — the
  platform boundary the wasm strategy exists for.
- **Threaded wasm**: modules built with shared memory don't parse in JSC;
  `Atomics.wait` impossible. Single-threaded wasi builds (CPython's shape)
  are on the viable side — measured on oxc and rolldown.
- **TLS server**: reachable via Network.framework + a SecIdentity, but the
  keychain step is unverified inside the sandboxed app; refusal stands with
  the corrected reason.
- zstd (absent from Apple's Compression), `crypto.subtle` (deliberately
  absent so feature detection falls back), SharedArrayBuffer across workers.
- **SPI in use**: unhandled-rejection exit codes ride
  `JSGlobalContextSetUnhandledRejectionCallback` via dlsym — one removable
  seam, App Store review risk recorded in system.md §8. A ship decision is
  the user's.

## Open leads (tracked, unclaimed)

- vitest stops at its worker handshake (exit 13) — everything ruled out is
  recorded; wants a fresh session.
- The `reachable` audit lists 7 refusals node doesn't share; the `shapes`
  audit lists ~17 Buffer internals some packages touch; `path.matchesGlob`
  has its 1824-case corpus gathered but no decision.
- `sharp` needs native bindings — a wall, listed so nobody rediscovers it.
- vs-code branch items (ROADMAP): `git clone` in the project picker, editor
  upgrades, ssh, the Preview container, four tracked shell gaps.
- Android parity for T/F/G — decision recorded in AGENTS.md (WebView +
  `@JavascriptInterface` path); no code yet.

## Blocked on the user

- Credentialed claude-code run (needs a real API key/session).
- The SPI ship decision (above).

## How to re-verify

`verify/verify.sh` — see [verify/README.md](verify/README.md). Requires
swiftc, real node v22, and pyte. The suite was rescued from session-scoped
scratch storage on 2026-07-31; it is the reproducibility anchor for every
claim in this file.

That rescue was incomplete, and it took a full run to notice: seven
harnesses depended on files the scratch directory had and the repo did not —
five on `node_modules` trees, one on an RSA keypair, one on a pair of
captured claude-code frames. They failed on a clean checkout, which means
the suite as committed had **never** been green; the "128 passed" recorded
at 41d7fe8 was the scratch copy. Each now creates what it needs on first
run (installing through the engine's own package manager, which is itself
part of what is tested) and the captured frames are checked in. A suite that
only passes on the machine that wrote it is not evidence.
