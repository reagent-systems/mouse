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
| **G** — the Node layer | Node 20-surface runtime on JavaScriptCore: modules, streams, fs, net/http/1.1+2, crypto, workers, child processes, vm, WASI | **Done** (this run) | `swift/Mouse/NodeEngine.swift` + `NodeSockets`/`NodeWatch`/`NodeKeys`/`NodeScrypt`/`NodeBrotli`/`NodeDNS`. ~88-gate suite green at 953dd98 (`verify/`), fixtures byte-identical to real node v22 |
| **D** — web toolchain | tsc, bundlers, dev servers | **Largely done**, as a byproduct of G | tsc + `tsc --watch`, webpack, esbuild-wasm, vite dev (HMR) and vite build (rollup-wasm) all gated (`verify/esbuild`, `devserver`, `hmr`, `firstrun`). Remaining piece is the Preview surface (phase C) |
| **B** — WebView JIT | Move JS/wasm execution into WKWebView for JIT speed | **Not started — optional** | Measured: everything runs interpreted; the JIT buys speed, not capability (system.md:2094). No longer a prerequisite for anything |
| **C** — Preview container | In-app viewing surface for what dev servers serve; LAN hosting | **Not started** | The server half works (vite serves clients outside the app — gated in `verify/devserver`); no in-app viewer exists |
| **E** — wasm runtime processes | Real processes: `$PATH`, executable bits, `ps`/`kill`/`&`, pipes between programs; other languages (Python first) as wasm32-wasi artifacts | **Partial, bottom-up** | Done inside G: WASI preview 1 with rights enforcement (`verify/wasi`), wasm execution proven (yoga, esbuild, rollup). Missing: the process layer, and a written plan — compile.md "Phase 3" covers the ground under a different number; no phase-E section exists in system.md |

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

- **On-device live run** — never happened; blocked on
  `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`.
  Everything above is headless evidence.
- Credentialed claude-code run (needs a real API key/session).
- The SPI ship decision (above).

## How to re-verify

`verify/verify.sh` — see [verify/README.md](verify/README.md). Requires
swiftc, real node v22, and pyte. The suite was rescued from session-scoped
scratch storage on 2026-07-31; it is the reproducibility anchor for every
claim in this file.
