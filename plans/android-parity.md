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
pyte cross-check — 238 checks, reading `verify/` fixtures directly so the
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
- **3b — `fs`, and module loading. DONE.** `NodeFs` is the workspace-virtual
  filesystem (read/write/append, `stat` and `lstat` with node's full field set,
  readdir, mkdir, remove, rename, chmod, statfs) and `ModuleResolver` is node's
  resolution algorithm — both pure Kotlin in `:node`, both gated against **real
  `node` itself**: `stat` against node's own `Stats`, and every resolution case
  against `require.resolve` in the same tree. The loader that evaluates what
  they resolve is JavaScript in `node-host.js`, because only the engine can run
  a module; that is the same line `NodeEngine.swift` draws. The entry script is
  now a MODULE, as it is on iOS, so `require` works in the one file a user is
  most likely to write. `:nodecheck` went 87 → 310 checks and now runs
  `verify/fsparity` through the Android bridge against the same `node.txt`.
  Deferred with reasons named per surface: `fs.watch` (inotify is
  `android.os.FileObserver`, framework, plus a host→JS event path that arrives
  with the socket layer) and ES modules (`require()` of one refuses with node's
  own `ERR_REQUIRE_ESM`; iOS transpiles, Android has no transpiler).
- **3c — sockets, `net`/`http`, DNS. DONE.** `NodeSockets.swift` is
  `kotlin/node/.../NodeSockets.kt`: one Java NIO selector thread owning every
  channel, not a thread per socket, because "a dev server with 50 keep-alive
  connections must not cost 50 threads" is sharper on Android than on iOS.
  `NodeDns` speaks DNS on the wire, name decompression included, because
  Android ships no JNDI and has no `/etc/resolv.conf` — the nameservers come
  from `ConnectivityManager`. `NodeHttp` is the TLS transport behind `fetch`,
  delivered incrementally so the head arrives before the body. `:nodecheck`
  went 310 → 422, driving the table against REAL `node` peers in both
  directions, and the on-device check went 45 → 64.

  Three bugs got through the JVM gate and were caught by the emulator, which
  is the whole argument for the rule: `closeAll` tearing the table down from
  the caller's thread (NPE in the JDK's own deregister), the resulting
  `ClosedSelectorException` being unchecked and therefore fatal on Android but
  merely printed on the JVM, and — the one that would have sunk leg (b) — the
  loop ending a program while its main module was still running, because
  `evaluateJavascript` returns before the renderer process has executed it.
  `net.createServer().listen()` on the first line of a script reported exit 0
  one millisecond before the bind crossed the bridge.

  Still deferred, each for a reason true NOW: unix-domain sockets
  (`UnixDomainSocketAddress` is API 34 against minSdk 26), the `cluster`
  descriptor handoff (`java.nio` will not adopt an fd it did not open), and the
  `WebSocket` global (no client in the JDK or the framework, and invariant #4
  forbids adding one — the `ws` PACKAGE rides these sockets and works).
- **3d** — crypto, workers, child processes; then `npm`/`npx`/`npm run` in
  Kotlin msh.

**4 — Runtimes.** Reuse `Runtimes.json` unchanged; port `RuntimeStore` +
the zip reader; `pkg install python` and `pkg install ruby` on Android.

**5 — Phase A: the shell LANGUAGE. DONE.** `ShellLanguage.swift` is
`kotlin/shell/src/.../ShellLanguage.kt` — lexer, AST, recursive-descent
parser and arithmetic, ported structurally intact — and the executor half of
`Shell.swift` joined `MouseShell`: `if`/`elif`/`else`, `for`, `while`/
`until`, `case`, functions with their own positional frame and `local`
scope, `break`/`continue`/`return`/`exit` as non-local control flow,
`test`/`[`, `$(…)`/backticks, `$((…))`, the `${…}` operators, field
splitting by quote context, `set -e`/`-x`/`-o pipefail`, `read`, compound
redirects, and `eval`/`source`/`.`/`sh`/`./script.sh`. `&` still refuses,
for the reason the Swift file gives. The corpus also proved four built-ins
were missing or wrong (`chmod`, `uname`, `mkdir -p` making a directory
called `-p`, `touch` taking only its first file) and that `globToRegex`
mangled bracket ranges — one real `fnmatch` (`ShellPattern`) now serves case
patterns, `${x##…}` stripping and globs alike.

Gated by `./gradlew :shellcheck:run`, a port of `verify/shell/main.swift`
that is DIFFERENTIAL in the same way: the same 25 scripts through msh and
through the real `/bin/sh`, each side in its own scratch directory,
comparing stdout and exit status. **All 25 match, and none diverge** — the
same result STATUS.md records for iOS on the same corpus.

The move that made it gatable: `MouseShell` was in `:app`, so no pure-JVM
harness could construct one, which is exactly why it was the last shared
component with no gate. It is now `:shell`, carved out like `:terminal`,
`:packages` and `:node` before it, coroutine-free like `:packages` — the API
is blocking, `Terminal.kt` wraps it in `withContext(Dispatchers.IO)`, and
cancellation arrives as `Context.isActive` so a streaming `ping` still stops
on a keypress.

## Stop condition

The same three legs the iOS loop ended on, each on an Android emulator,
each with a screenshot:

- **(a)** `pkg install python` then `python hello.py` prints.
- **(b)** a node dev server runs and answers a real HTTP request from the
  host machine.
- **(c)** an interactive TUI — `npx create-vite` — renders its menu, takes
  input through the key strip, and advances through its prompts.

  **(a) PASSES.** `pkg install python` then `python hello.py` prints
  `python says 42` on Pixel_9, by screenshot. The launch path is in — `node
  script.js`, `node -e`, and the catalog's own commands through
  `MouseShell.NodeRun` → `NodeRunner` → `NodeWebView` — and three
  platform-specific walls came down with it: V8 refuses a synchronous
  `WebAssembly.Module` over 8 MB on the main thread (so the generated WASI
  bootstrap uses the async `instantiate`), the shared bootstrap REPLACES V8's
  async wasm API with the synchronous one for a JSC reason that inverts here
  (so the host restores V8's own across the load), and `randomBytes` was
  deferred while CPython asks for entropy before `main` (now `SecureRandom`).
  Terminal output is also a byte stream now, cut on newlines rather than per
  write, because `print('a', 42)` arrives as four `fd_write`s.

  **(b) PASSES.** `node server.js` runs an `http.createServer` inside the app,
  and `curl http://127.0.0.1:18080/hello` from the HOST machine — through
  `adb forward tcp:18080 tcp:8080` — answers `hello from mouse on android`
  with a real 200, keep-alive and chunked encoding. The server logged
  `request GET /hello` and `request GET /second` in the terminal as they
  arrived, which is the half a curl transcript alone would not show.

  One defect found by running and NOT yet fixed:

  - **`process.platform` answers `darwin` on Android.** The bootstrap hardcodes
    it and is a verbatim iOS copy under a drift gate, so the fix is a host
    override applied after load, with a gate of its own. Packages branch on
    this — napi-rs already does — so it is not cosmetic.

  One known gap stands in the way of (c) and is not covered by any milestone
  above: **backspace does not reach a running program.** While a program owns
  the keyboard the prompt field is held empty, so Compose fires no
  `onValueChange` for a deletion and the keystroke is lost. `create-vite` asks
  for a project name, so the leg cannot pass without it. The fix is the usual
  one — keep a sentinel character in the field so a deletion is always an edit,
  and translate edits into keys — but it is deliberately NOT written yet,
  because there is no program on Android that can show a backspace arriving,
  and unverifiable code is what this plan exists to avoid. It lands with 3d,
  when a real TUI can prove it.

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
