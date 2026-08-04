# Android parity: everything the iOS app can do

The Kotlin app (`kotlin/`, ~2,600 lines) is a real parity app for the
carousel, workspaces, git, GitHub and a from-scratch `msh` — but phases
**T** (terminal screen), **F** (package manager) and **G** (the Node layer)
are iOS-only by a decision recorded in AGENTS.md. This plan triggers that
decision deliberately, on the user's instruction, and says which path it
takes and why.

## What Android actually permits

The premise that started this — "Android isn't stuck by the JIT problem" —
is half right, and the half that is wrong decides the architecture.

**Free on Android, blocked on iOS:**
- **JIT.** No page-level code-signing enforcement. A WebView JITs
  JavaScript. The interpreted-speed ceiling that shapes the whole iOS
  engine simply is not there.
- **Process creation.** `fork`/`exec` work. The app already ships an `sh`
  engine that runs `/system/bin/sh`, which iOS can never do.

**Blocked on Android too, for a different reason:**
- **Executing downloaded binaries.** Since API 29, an app targeting 29+
  cannot exec a file from its own writable data directory — SELinux
  refuses. This app targets SDK 35. So the Termux model ("`pkg install`
  fetches real ARM binaries and runs them") is NOT available without either
  dropping targetSdk (Play Store will not accept it; this is why Termux
  distributes on F-Droid) or shipping the binaries inside the APK.

**The one genuine Android unlock:** binaries in the APK's native-library
directory ARE executable. A real `node` could ship that way.

## The three paths, and the choice

**A — bundle real binaries in the APK.** Ship node (and later python) as
native libs. No engine to write; real V8 with JIT. Costs: the runtime set
is frozen at build time, every update needs a release, and the APK carries
every runtime whether or not a user wants it. This is the thing the iOS
side deliberately rejected ("runtimes are installed as data, never
bundled") and it forfeits the property the user has asked for most
consistently: install whatever you need.

**B — port the engine into a WebView. ← recommended, and what this plan
does.** The Node engine's JS bootstrap is ~72 % portable (measured, per
system.md); the host bridge is the 28 % that gets rewritten in Kotlin
against `@JavascriptInterface`. Runtimes stay wasm, downloaded — so the
exec restriction never applies, and `swift/Runtimes.json` is reused
verbatim because the catalog is data. JIT comes free from the WebView, so
Android gets the same capability as iOS and is faster at it.

**C — Termux model, sideload only.** Most capable; gives up the Play Store.
Only worth it if distribution is F-Droid/APK anyway.

**Open question for the user, and the only thing that would change this
plan: does the Android app need to stay Play-Store-shippable?** If no, C
becomes worth costing. Everything in Milestones 1–3 below is common to all
three paths, so this plan starts without the answer.

## Milestones

Each ends in a commit with evidence, and nothing counts until it runs on an
emulator (AVDs present: `Pixel_9`, `Medium_Phone_API_36.0`, `Medium_Tablet`;
SDK at `~/Library/Android/sdk`, JDK 21; nothing is on PATH — export
`ANDROID_HOME` and use `$ANDROID_HOME/platform-tools/adb`).

**1 — Phase T: the terminal screen. DONE.** `TerminalScreen.swift`,
`TerminalWidth.swift`, `AnsiParser` and the `TerminalProgram` contract are
`kotlin/terminal/`, gated by `:screencheck` against the iOS corpus and the
pyte cross-check — 202 checks, reading `verify/` fixtures directly so the
platforms cannot drift. `PagerProgram` came across with them and carries the
same 20 assertions `verify/main.swift` makes; `TopProgram` did not, because
Kotlin msh has no `top` builtin to supply its snapshot.

The platform half is in `kotlin/app/Terminal.kt`: session-side program
hosting (screen + parser, launch, key routing, grid sizing, the inline-TUI
last frame joining the scrollback), a Compose grid renderer (run-length
styled rows, xterm 256-color, identity keyed on `screenGeneration` — the
`.id()` fix from iOS), and the key strip `up down left right esc tab canc`.
`less` reaches it through `Context.launchProgram`. The container no longer
moves when the soft keyboard opens (`adjustNothing`), matching iOS.

**2 — Phase F: the package manager. DONE.** `PackageManager.swift` is
`kotlin/packages/` — semver, npm registry, hoisting resolver, integrity,
manifest, `npm:` aliases, the wasm/wasi substitutions, and `TarGz` moved
across from `Workspace.kt` the way iOS moved it out of `Workspace.swift`.
Gated by `./gradlew :pkgcheck:run` against the same fixtures: the semver
corpus, resolution vs real `pnpm install --lockfile-only`, and real installs
proven by real `node` requiring out of the tree. Kotlin already had tar+gzip
and `MessageDigest`; it did NOT have JSON that works off-device (`org.json` is
framework-only), so the module carries a hand-written reader/writer.
`npm run`/`npx` are deferred to milestone 3 — they exist to RUN what they
install, so they need the Node layer first.

**3 — Phase G: the Node layer in a WebView.** The JS bootstrap moves
across largely intact; the Kotlin bridge implements what `NodeEngine`'s
Swift half does (fs, sockets, timers, child engines). Sockets are the
biggest rewrite: `NodeSockets.swift` → Java NIO.

- **3a — the foundation. DONE.** The bootstrap (13,993 lines) is copied
  verbatim into `kotlin/app/src/main/assets/node-bootstrap.js` and
  re-extracted from `swift/Mouse/NodeEngine.swift` and diffed on every gate
  run, so the copy cannot drift. `kotlin/node/` holds what is pure — the
  extraction, the `__mouse` protocol, the process globals, the event loop's
  bookkeeping — and `kotlin/app/.../nodehost/NodeWebView.kt` is the headless
  WebView host. Wired: `console.log`/`error` to Kotlin, `process` (argv, env,
  cwd, version, exit code), and timers with the tick discipline the iOS engine
  documents. Gated by `./gradlew :nodecheck:run` (87 checks) plus an
  adb-triggerable on-device check for the WebView, which no JVM harness can
  reach. Two things the iOS engine never had to solve turned up here: the
  bridge cannot carry a function, and the WebView's `Window` already owns some
  of the globals the bootstrap assigns (see `kotlin/README.md`).
- **3b** — `fs`, and module loading (`require` over `node_modules`).
- **3c** — sockets (`NodeSockets.swift` → Java NIO), `net`/`http`, DNS.
- **3d** — crypto, workers, child processes; then `npm`/`npx`/`npm run` in
  Kotlin msh.

**4 — Runtimes.** Reuse `Runtimes.json` unchanged; port `RuntimeStore` +
the zip reader; `pkg install python` and `pkg install ruby` on Android.

## Stop condition

The same three legs the iOS loop ended on, each on an Android emulator,
each with a screenshot:

- **(a)** `pkg install python` then `python hello.py` prints.
- **(b)** a node dev server runs and answers a real HTTP request from the
  host machine.
- **(c)** an interactive TUI — `npx create-vite` — renders its menu, takes
  input through the key strip, and advances through its prompts.

Plus: the Kotlin app builds clean, the existing carousel/git/workspace
behaviour is unregressed, and the iOS app is untouched.

## Rules

- **iOS is frozen for this loop.** No file under `swift/` changes. If a
  bug in the shared *design* surfaces, note it; do not fix it here.
- Parity is by faithful re-implementation, never a bridge (invariant #5).
  Zero third-party dependencies (invariant #4) — the Kotlin app has held
  that line so far, including hand-written tar.
- The gesture law and the focused-editor stand-down apply identically.
- Verify on the emulator before every boundary commit: build, install,
  launch, drive, screenshot, read it. A green Gradle build is not evidence
  the app works — that lesson cost the iOS side a whole phase.
- Port `verify/` harnesses where the logic is shared. A Kotlin port of a
  gated iOS behaviour should be gated the same way, against the same
  fixtures, or the parity claim is unfalsifiable.
