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
- **An agent CLI starts and renders its UI on the phone.** claude-code
  1.0.128 installs through our own npm, reports `1.0.128 (Claude Code)`,
  and its React/ink TUI draws its bordered `Welcome to Claude Code` frame
  on the phase-T screen. Screenshot at 23:58.
- **claude-code's CURRENT releases cannot run here, and that is a change in
  the package, not a regression in the engine.** `@anthropic-ai/claude-code`
  now ships `bin/claude.exe` — a per-platform NATIVE binary — with
  `cli-wrapper.cjs` as a fallback that spawns it. iOS will not execute
  unsigned native code, so this is the platform wall the wasm strategy
  exists for, reached from a new direction. The JS-bundle versions (1.0.128
  and its era) still run. Any claim here about "claude-code" means those.
- **Interactive TUIs work.** `npx create-vite` walks its whole flow on the
  phone: text prompt, framework menu, variant menu, install confirmation —
  every transition painting live, colours intact, selections tracking.
  Five defects stood between the first attempt and that, each reproduced
  before it was fixed: `tty.WriteStream` was `process.stdout` rather than a
  real Writable (so a prompt library's own `_write` hook — where it reads
  the typed value — was dead code, and the echo sprayed the live frame);
  readline auto-detected `terminal` from its input instead of its output;
  stdin `unpipe` was a no-op and `once` aliased `on`, leaking a listener
  per prompt; readline defaulted `output` to stdout, so a deliberately
  silent line editor echoed into the frame at transition time; and engine
  writes crossed to the main actor as independent tasks, which are
  unordered — under burst input a stale frame could land last. Delivery is
  now an ordered channel. The last one was in the VIEW: the grid read
  `screenGeneration` for observation, but each row is a `Text` diffed by
  value, so a multi-row transition redraw could leave rows SwiftUI judged
  unchanged. The grid's identity is now the generation — a new generation
  is a new screen, which is what a terminal frame is.
- **Ruby runs, and was added without touching Swift.** `pkg install ruby`
  fetches the official `ruby.wasm` build, hash-checked, and
  `ruby hello.rb` prints. The catalog is `swift/Runtimes.json`: a language
  is a JSON entry with its archive, interpreter path, commands and env —
  `verify/pkgruby` greps `swift/Mouse` for the language's name and fails if
  it appears.
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
- `verify/napiwasi` has gone stale for a reason that is not ours: neither of
  its two packages publishes a `…-wasm32-wasi` optional dependency any more
  (rolldown dropped it at 1.2.x, oxc-parser at 0.143), so `wasiBinding` finds
  nothing to install and the gate reports a wall that has moved. Found by the
  Kotlin port of the same check, which now asserts the RULE on a synthetic
  napi-rs-shaped package and keeps one live-registry leg on a package that
  still ships one (`unrs-resolver`). Repoint the Swift harness the same way.
- vs-code branch items (ROADMAP): `git clone` in the project picker, editor
  upgrades, ssh, the Preview container, four tracked shell gaps.
- Android parity for T/F/G — plan at `plans/android-parity.md` (WebView +
  `@JavascriptInterface` path). Milestone 1 (phase T's pure-logic layer) is
  in: `kotlin/terminal/` holds the screen, parser, width table and key
  encoding; `./gradlew :screencheck:run` gates them against the iOS corpus
  and the same `verify/` fixtures, pyte cross-check included. Milestone 2
  (phase F) is in: `kotlin/packages/` holds semver, the registry client, the
  hoisting resolver, integrity, the manifest, `npm:` aliases, the wasm/wasi
  substitutions and `TarGz`; `./gradlew :pkgcheck:run` gates it the same way
  the iOS side is gated — semver corpus, resolution against real `pnpm
  install --lockfile-only`, and real installs proven by real `node` requiring
  out of the tree (140 checks, MATCH). Milestone 3a (phase G's foundation) is
  in: the JS bootstrap — 13,993 lines, the portable 72 % — is copied verbatim
  out of `swift/Mouse/NodeEngine.swift` into
  `kotlin/app/src/main/assets/node-bootstrap.js` and re-extracted and diffed on
  every gate run, so the copy cannot drift; `kotlin/node/` holds the bridge
  protocol, the process globals and the event loop's bookkeeping;
  `kotlin/app/.../nodehost/NodeWebView.kt` is the headless WebView host, with
  `console`, `process` (argv/env/cwd/version/exit) and timers wired.
  Milestone 3b is in: `NodeFs` is the workspace-virtual filesystem and
  `ModuleResolver` is node's resolution algorithm, both pure Kotlin and both
  gated against **real `node` itself** — `stat` against node's own `Stats`,
  every resolution case against `require.resolve` in one real tree — with the
  CommonJS loader that evaluates what they resolve in `node-host.js`, the same
  split `NodeEngine.swift` makes. The entry script is a module now, so `require`
  works in it. Milestone 3c is in too: `NodeSockets` is a Java NIO selector
  table (one thread, not one per socket), `NodeDns` writes and parses DNS on
  the wire because Android has no `/etc/resolv.conf` and no JNDI, and
  `NodeHttp` is the TLS transport behind `fetch` — so `net`, `http.createServer`
  and `dgram` are real. `./gradlew :nodecheck:run` gates all of it (422 checks,
  MATCH), including `verify/fsparity`, `verify/neterrors` and `verify/reqsock`
  run through the Android bridge against the same `node.txt`, and the socket
  table driven against real `node` peers in both directions; the WebView itself
  is gated on device by a debug broadcast (`NodeCheckReceiver` — see
  `kotlin/README.md`), now 64 checks, MATCH.

  That device gate earned its keep at 3c: it caught three bugs behind a green
  422-check JVM run, one of which — the loop concluding a program while its own
  main module was still executing in the WebView's renderer process — made
  `net.createServer().listen()` report exit 0 before the bind crossed the
  bridge, and would have made a dev server impossible. Phase T's platform half is in as
  well: `PagerProgram`, session-side program hosting, the Compose grid renderer,
  key routing and the key strip (`up down left right esc tab canc`), with `less`
  in msh to drive them — verified on the emulator by paging a 200-line file by
  touch. Milestone 4's INSTALL half is in: `RuntimeCatalog`/`RuntimeStore`/
  `ZipArchive` in `kotlin/packages/`, reading `swift/Runtimes.json` itself
  (copied into assets by a Gradle task, so the repo holds exactly one catalog),
  and `pkg list | install | remove` in Kotlin msh. `pkg install python` and
  `pkg install ruby` both land on the emulator — 30 MB of `python.wasm` and a
  35 MB `bin/ruby`, hash-verified. Still open: 3d — crypto, compression, `vm`,
  workers and child processes, plus `fs.watch`, ES modules, unix-domain
  sockets, the `cluster` descriptor handoff and the `WebSocket` global, each
  refusing by name with its own reason; and `npm`/`npx`/`npm run` in Kotlin
  msh, which wait on G because they exist to run what they install.
- **All three Android stop-condition legs now pass on an emulator, each with a
  screenshot.** (a) `pkg install python` then `python hello.py`
  prints `python says 42`; (b) a `node server.js` dev server inside the app
  answers a real `curl` from the host machine over `adb forward`; (c) `npx
  create-vite` renders its prompts on the phase-T grid, takes a typed project
  name, and moves its framework selection by taps on the key strip. Getting
  there took the msh→engine launch path (`MouseShell.NodeRun` → `NodeRunner` →
  `NodeWebView`) plus three walls that are this platform's alone: V8 refuses a
  synchronous `WebAssembly.Module` over 8 MB on the main thread, the shared
  bootstrap REPLACES V8's async wasm API with the synchronous one for a
  JavaScriptCore reason that inverts here, and `randomBytes` was deferred
  while CPython asks for entropy before `main`. Leg (c) additionally needed the
  ES module transpiler ported (`EsmTranspiler`, from `rewriteImportForms` and
  `transpileESM`, gated differentially against real node), the T↔G join so a
  program can own the phase-T screen, ONLCR — without which every frame sheared
  diagonally — and two faults that together swallowed every keystroke:
  `stdinIsComplete` handing an interactive program an already-ended stream, and
  the prompt field sending its whole composing region instead of the delta.
- **Asymmetric keys are DONE on Android** — EC/RSA/Ed25519 signing in both
  signature encodings, RSA-PSS, RSA as a cipher (OAEP, PKCS#1 v1.5, the type-1
  pair), key generation and ECDH, all fourteen bridge methods over one PEM/DER
  reader in `NodeKeys`. Graded both directions against real node
  (`:nodecheck` 573 → 777) and end to end on the phone (on-device 75 → 90).
  `npm install jsonwebtoken` then RS256 and ES256 tokens signed and verified in
  the app, tampered token refused.
- **Three bugs, and each needed a different KIND of gate — that is the finding.**
  The curve-name split (`prime256v1` vs `secp256r1`) fell to the JVM corpus.
  RSA-PSS fell to the device with 781 JVM checks green, because Android ships
  Conscrypt, which registers `SHA256withRSA/PSS` and not the JDK's generic
  `RSASSA-PSS`. `jsonwebtoken` fell to neither: `crypto.createSign` takes an
  OpenSSL algorithm name and `jwa` asks for `RSA-SHA256`, a normaliser iOS has
  and this had not ported — invisible to every check written by hand, because a
  hand-written check passes the digest node's short way. A corpus proves the
  maths, a device program proves the platform, a real package proves the API.
- **A shipped correctness bug in `pbkdf2`, found by writing the thing next to
  it.** The old implementation went through `SecretKeyFactory`, and the comment
  defending it claimed a latin-1 char mapping round-trips so any password byte
  survives. It does not: the JDK encodes those chars as UTF-8, so every byte
  from 0x80 up became two and the derived key silently disagreed with node's.
  The corpus could not see it because every case in it used an ASCII password.
  PBKDF2, HKDF and scrypt are all written out over `Mac` now, so no charset and
  no provider spelling enters any of them; `md5` works as a side effect, which
  the factory route could not offer and node does. `scrypt` and `hkdf` are
  IMPLEMENTED — that deferral entry is gone, not reworded. On the phone, scrypt
  reproduces RFC 7914's published vector and pbkdf2 now agrees with node on the
  exact input where it used to differ.
- **Six Android deferral REASONS have turned out to be false, and that is now
  the finding rather than six incidents.** brotli, ciphers, asymmetric keys,
  `vm`, `rewriteImports`, `unhandledRejection`. Two cost real capability that
  was buildable at the time it was refused. The partition gate proves a refusal
  still REFUSES; nothing proves its reason is still TRUE, and that asymmetry is
  the largest known hole in the Android suite. The newest: `unhandledRejection`
  claimed a WebView has no hook — it has one, on the console channel, which
  carries a string where node hands a handler the rejection's value. Exit codes
  are now correct in both branches (no listener → print and exit 1; a listener
  → no exit) and the listener is still never called, wired as a half rather
  than rounded up. Verified on the emulator both ways.
- Running an installed runtime on Android is closer than the plan assumed, and
  for a reason worth recording: the shared bootstrap reaches for the standard
  `WebAssembly.*` API rather than shipping an interpreter, so Android gets V8's
  native JIT-compiled wasm for free, and the WASI layer above it is shared JS
  resting on the `fs` bindings 3b already landed. What is missing for
  `python hello.py` is the msh side — `node` and the catalog's `commands` are
  still unwired in Kotlin msh — not an engine.

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
