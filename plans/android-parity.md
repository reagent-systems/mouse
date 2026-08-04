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
- **3d — crypto's arithmetic half. DONE; the rest still refuses by name.**
  `NodeCrypto` in `:node` — digests, HMAC, PBKDF2 and `randomUUID` on the JCA,
  which is the platform's own and so adds no dependency, the same bargain
  CryptoKit is on iOS. It lives in the PURE module because none of it is
  framework, which is what lets `:nodecheck` grade it against real `node`
  computing the same digests rather than against pinned vectors: the errors
  worth catching are translation errors (node says `sha256`, the JCA says
  `SHA-256` and `HmacSHA256`; an empty HMAC key is legal to node and rejected
  by the JCA), and every one of them shows up as a different digest. 53 checks.

  **zlib too.** `NodeZlib`, on `java.util.zip`. iOS drives zlib's own `z_stream`
  and gets the framing free from `windowBits` — 15 is the zlib wrapper, −15 raw,
  15+16 gzip, 15+32 auto-detect — and `java.util.zip` exposes exactly ONE of
  those as `nowrap`. So gzip's 10-byte header, its CRC32/ISIZE trailer and the
  gzip-or-zlib auto-detect are written here, one-shot and streaming sharing the
  same framing rather than two implementations that could disagree. 50 checks,
  graded BOTH DIRECTIONS against real node, because a codec wrong in a
  self-consistent way round-trips through itself perfectly.

  **Symmetric ciphers too** — AES-GCM, ChaCha20-Poly1305, and AES in CBC/CTR/ECB.
  An earlier note here lumped them in with key management, which was WRONG:
  they take the key the caller supplies, so they are arithmetic like the
  digests. iOS splits them between CryptoKit's AEADs and CommonCrypto's block
  modes; the JCA has all of it under one `Cipher`. 38 checks, both directions,
  and asserting the ciphertext and tag are byte-IDENTICAL to node's rather than
  merely mutually decodable — plus that a tampered GCM tag refuses, which is
  the check that separates authenticated encryption from encryption.

  Still deferred, and the line is now where it should have been: ASYMMETRIC
  KEYS — EC/RSA/Ed25519 signing, ECDH, key generation and parsing. The JCA has
  the primitives (`KeyPairGenerator`, `Signature`, `KeyAgreement`,
  `KeyFactory`), so this is not a missing capability and the reason must not
  pretend it is. The work is the KEYS: every one of these bridge methods takes
  a PEM, and reading one means PKCS#8, SEC1, PKCS#1 and SPKI, identifying the
  curve, and emitting ECDSA signatures in DER or raw as the caller asks —
  fourteen bridge methods over one shared parser. Ed25519 adds a second wall:
  the JCA gained it at API 33, against this app's minSdk 26, so it needs a
  runtime check rather than a straight call.

  **`vm` is DONE, and its refusal had been wrong.** It said "a WebView gives no
  way to make another context reachable from this one". Measured on a device:
  an `about:blank` iframe is same-origin, so its `contentWindow` is reachable,
  with its own globals AND its own intrinsics (`w.Array !== Array`) — exactly
  what `vm.createContext` needs. It lives entirely in the shim, because the
  context is a JavaScript object and no Kotlin is involved. Where it falls short
  of node is written down rather than glossed: node's sandbox is a live proxy,
  this one is copied in before a run and out after, so the two agree at every
  `runInContext` boundary and can disagree inside one.

  **`rewriteImports` was a fifth**, and the cheapest of them: its refusal said
  "Android has no transpiler, which is also why `require()` of an ES module
  refuses with ERR_REQUIRE_ESM". 3e made both halves false and left the surface
  behind — it is one line over `EsmTranspiler`, the same rewriter the loader
  already runs. Gated directly rather than only through the ESM corpus, because
  its CALLERS differ: the loader rewrites a file, this rewrites a string a
  program built at runtime, and what must not differ is what they refuse to
  touch — an `import(` inside a string, a comment, or after a dot.

  **ASYMMETRIC KEYS ARE DONE**, and the deferral reason turned out to be right
  about the shape of the work: the JCA had every primitive, and the work was
  the KEYS. `NodeKeys` is one reader under all fourteen bridge methods — PEM
  across PKCS#8, SPKI, SEC1 and both PKCS#1 forms, identified by the algorithm
  OID rather than by trying imports until one stops throwing, because the JCA's
  exceptions differ across API levels and a trial import cannot separate X25519
  from Ed25519. `KeyFactory` reads only PKCS#8 and SPKI, so the other three
  grammars are RE-WRAPPED, which needs a DER writer beside the reader. Then
  ECDSA in DER and `ieee-p1363`, RSA in PKCS#1 v1.5 and PSS, RSA as a cipher
  under OAEP and the type-1 primitive, key generation, and ECDH — which touches
  the parser not at all, since `createECDH` has no envelope and its keys are a
  bare scalar and an uncompressed point.

  Graded against real node in both directions, because a signature scheme wrong
  in a stable way verifies its own output perfectly: node signs and this
  verifies, this signs and node verifies, and RSA PKCS#1 v1.5 is compared byte
  for byte on top. `:nodecheck` 573 → 777.

  **THREE BUGS THE JVM CORPUS COULD NOT SEE**, in ascending order of how much
  they say about this project's gates:

  1. P-256 would not generate. node and OpenSSL call that curve `prime256v1`;
     the JDK and Android call it `secp256r1`. P-384 and P-521 spell the same in
     both worlds, so it failed on exactly one curve. Caught by the corpus.
  2. RSA-PSS failed ON THE DEVICE with 781 JVM checks green. A JDK harness gets
     SunRsaSign, which registers the generic `RSASSA-PSS`; Android ships
     **Conscrypt**, which does not register that name at all — it registers
     `SHA256withRSA/PSS`, digest baked in. Caught by `NodeKeysSmoke`, the
     device-only program written for precisely this, on its first run.
  3. `jsonwebtoken` failed on the device with the corpus green AND the device
     smoke green. `crypto.createSign` takes an OpenSSL ALGORITHM name, not a
     bare digest, and `jwa` signs RS256 by asking for `RSA-SHA256`.
     `NodeEngine.swift` has a `digestName` normaliser for exactly this and it
     was not ported. Nothing synthetic caught it because every check written by
     hand — mine and the smoke's — passes the digest node's short way. A real
     package found it in one run.

  The lesson stacks: a corpus proves the maths, a device program proves the
  platform, and only a real package proves the API's actual surface. The
  workspace ran `npm install jsonwebtoken` (15 packages, real tree) and then
  signed and verified RS256 and ES256 tokens on the phone, with a tampered
  token refused. ES256 goes through `ecdsa-sig-formatter`, so a real library
  exercised the `ieee-p1363` conversion rather than a check that knew to ask.

  **`scrypt` and `hkdf` are DONE too, and writing them found a bug in the code
  beside them.** Their reason had just been rewritten to say they were unwritten
  rather than unavailable — short constructions over `Mac` — which by this
  loop's own pattern is an invitation. Both are written now, graded BYTE FOR
  BYTE against real node (they are deterministic, so a round trip would prove
  nothing: a KDF's whole job is to agree with other implementations of the same
  RFC), and the deferral entry is gone rather than reworded.

  What that turned up: `pbkdf2`, already shipped and already gated, was WRONG
  for any password byte over 0x7f. It went through `SecretKeyFactory`, whose
  `PBEKeySpec` takes chars, and the comment defending it claimed a latin-1
  mapping round-trips. The JDK encodes those chars as UTF-8. Measured against
  real node for the password `ff fe 41`, the two disagreed completely. Every
  case in the corpus used an ASCII password, where the two encodings agree —
  the same blind spot that hid the `RSA-SHA256` normaliser, and for the same
  reason: a check written by hand uses the input the writer had in mind. All
  three KDFs are now computed over BYTES with no charset and no provider
  spelling anywhere, and `md5` works as a side effect. On the phone, scrypt
  reproduces RFC 7914's published vector.

  **OPEN, found by `jose` and reduced to three lines: `require()` of an ES
  module from a HAND-WRITTEN CommonJS file yields `{}`.** Not a jose problem
  and not a barrel problem — `require('./leaf.mjs')` where leaf.mjs is two
  plain named exports answers an empty object too.

  The mechanism is not a bug in the sense of broken code; it is a design
  decision whose blast radius was not seen. `node-host.js` returns a PROMISE of
  the exports when the required module is ESM, and says why: every transpiled
  import site reads `if (x instanceof Promise) x = await x`, and a module with
  top-level await genuinely is not finished yet. From a transpiled importer
  that is right. From a CommonJS file a user wrote by hand there is no such
  unwrapping, so `require('jose')` hands back a promise, `Object.keys` of it is
  empty, and the failure surfaces as `jose.generateKeyPair is not a function` —
  a message that points nowhere near the cause.

  Real node does neither: older node throws `ERR_REQUIRE_ESM`, and node 22
  returns the namespace synchronously for a module with no top-level await.
  Either is a defensible target and they are different amounts of work, so this
  is written down rather than guessed at. The entry path is unaffected —
  `npx create-vite` is an ES module and runs — which is exactly why nothing
  caught this until a real package was required from real user-shaped code.

  **`unhandledRejection` was a sixth, and false in a more interesting way than
  the rest.** It said "a WebView exposes no equivalent hook, so nothing can
  call this". There IS a hook — it is simply not the one the reason went
  looking for. Three probe programs on a device settled both halves: the DOM
  `unhandledrejection` event is present as API surface (`addEventListener` is a
  function, assigning `onunhandledrejection` sticks) and NEVER FIRES — four
  rejection sites, both registration styles, native V8 promises on the real
  window, 500 ms each, zero events. Chromium detects every one of them anyway
  and reports it on the CONSOLE channel, which `WebChromeClient` reads.

  That channel carries a formatted STRING where node hands a handler the
  `reason` VALUE, so it serves exactly one half of node's contract, and the
  half-capability is wired as a half rather than rounded up: **exit codes are
  correct in both branches** — no listener prints and exits 1, a listener does
  not exit — and **the listener is never called**, because synthesising an
  `Error` from console text is wrong the moment a program rejects with a
  string, a number, or an object carrying a `code`. So the bridge name stays
  DEFERRED (the engine-internal path really is unwired) while the behaviour a
  shell can observe is right. Verified on the emulator both ways, including
  that the fatal case dies at the checkpoint before its own 200 ms timer.

  Six reasons, found one at a time and then by reading the list. The pattern is
  now the finding: the partition gate proves a refusal still REFUSES, and
  nothing proves its reason is still TRUE. Two of the six cost real capability
  (`vm` was buildable since 3a, `rewriteImports` since 3e). A reason that names
  a platform limit deserves the same treatment as a claim in code — it should
  be re-measured when the platform or the tree moves under it, and until
  something gates that prose, re-reading it periodically is the only defence.

  Gated by `NodeVmSmoke`, the first DEVICE-ONLY program in the suite — an
  iframe needs a DOM and real node has none, so grading it in `:nodecheck` too
  would mean expecting different things of the two hosts, which is the trap the
  ES module refusal fell into. Brotli has no Android route at all: the
  platform decodes it inside its HTTP stack and exposes nothing to an app, and
  a third-party artifact is what invariant #4 forbids. `vm`, workers and child
  processes are untouched.

  `npm`/`npx`/`npm run` in Kotlin msh landed earlier, with the launch path.

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

  **(c) PASSES.** `npx create-vite` renders its prompts on the phase-T grid,
  takes a project name typed character by character, and moves its framework
  selection by taps on the key strip. Four things had to land:

  - **milestone 3e, the ES module transpiler.** `EsmTranspiler.kt`, ported from
    `rewriteImportForms` and `transpileESM`, gated differentially against real
    node on seven grammar cases, and wired into BOTH the resolver and the
    entry — the second because msh reads a bin itself and hands the text over,
    so the resolver never sees it. create-vite ships an ES module; before this
    it could not start at all.
  - **the T↔G join.** `NodeProgram` hosts a running engine as a
    `TerminalProgram`, and the engagement rule — ported and gated since phase T
    with nothing calling it — finally decides when a streaming program becomes
    a screen program.
  - **ONLCR.** A pty maps NL→CR-NL on output and we are the pty substitute.
    Without it every frame sheared diagonally, one column further right per
    line, because the screen is correctly xterm-faithful in treating LF as
    index.
  - **stdin, twice.** `stdinIsComplete` defaulted to TRUE — right for 3a, where
    nothing is attached and a reader must reach EOF rather than wait forever,
    and fatal for an interactive program, which is handed a stream that has
    ALREADY ENDED. It swallowed every keystroke, and it was also the whole of
    the "starts nothing at all on half its runs" intermittency: clack asks
    stdin for a line, EOF answers, the prompt cancels itself, and nothing is
    printed because from the program's side nothing went wrong. Separately, the
    prompt field sent its whole COMPOSING REGION on every change, so `mouse-app`
    arrived as `m` + `mo` + `mou` + … concatenated; keystrokes are the DIFF now,
    and nothing is written back into the field. Backspace falls out of the same
    change: a shrinking field is DEL.

  **`process.platform` is fixed too.** It answered `darwin`, which the bootstrap
  hardcodes and which is TRUE on iOS. The host now corrects it after load —
  `Bootstrap.platformScript`, alongside the wasm restore — to `android`,
  `os.type()` to `Linux`, and the arch to node's spelling of
  `Build.SUPPORTED_ABIS[0]`. It is not cosmetic: napi-rs's generated loader
  reaches for `<name>.<platform>-<arch>.node` before it will consider the
  WebAssembly build, so a wrong answer sends it hunting a darwin artifact on a
  phone. Gated in the SHARED smoke, with the driver applying the same script
  from the same function so the two hosts cannot answer differently; proven
  able to fail. On device: `platform android android / type Linux arch arm64
  arm64`.

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
