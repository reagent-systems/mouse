# AGENTS.md — the contract for AI agents working on Mouse

Humans should read this too: it doubles as the map of load-bearing decisions
that are cheap to break and expensive to rediscover. Every entry here was
paid for.

## Commands

```sh
# after adding/removing/renaming ANY source file:
cd swift && xcodegen generate

# build (the only automated check today):
xcodebuild -project swift/Mouse.xcodeproj -scheme Mouse \
  -destination 'generic/platform=iOS Simulator' build
```

Never edit `Mouse.xcodeproj` directly — it is generated from
`swift/project.yml`. There is no test target; verification is running the
app (see CONTRIBUTING.md). One exception: `Shell.swift` and
`GitCore.swift` are deliberately app-independent, so interpreter and git
changes verify headlessly: compile with a scratch `main.swift` of assertions
via `swiftc` and run. For GitCore, ALSO validate interop with the real CLI:
`git fsck --full` silent + `git status --porcelain` empty against a repo the
engine wrote; the packfile writer must pass `git index-pack --stdin`; the
reader must resolve a delta pack from `git pack-objects`; a push body
(pkt-line command + pack) must update a ref via `git receive-pack
--stateless-rpc`; a fetch body (want/have) must round-trip through `git
upload-pack --stateless-rpc` with the ACK/NAK preamble demuxed and haves
honored (incremental pack smaller than the full closure); and the merge
engine must match `git merge-file` on the line merge (clean + conflict
cases) and a real repo on the FF/three-way outcomes (`fsck` clean, both
parents present, byte-identical content).
`NodeSockets.swift` and `NodeWatch.swift` hand closures across queues by design.
That is stated in the types rather than warned about: `@Sendable` handler types,
`@unchecked Sendable` on the queue-confined `Entry`/`Watcher` classes (the
confinement to one serial queue is what makes it true), values handed to closures
instead of mutable vars, and a single `Carried` box for the one crossing that can
never be checked — a JSValue travelling to the JS thread, where it is only ever
called. Keep the build WARNING-FREE; these are errors under the Swift 6 language
mode.
Pack inflate uses **libz** (`-lz` in project.yml), not the Compression
framework, which can't delimit concatenated zlib members.
`TerminalScreen.swift` and `TerminalPrograms.swift` are also
app-independent: verify the screen against xterm semantics AND cross-check
against a known-good emulator (`pip install pyte`; feed both the same
escape streams — structured + seeded-random — and diff final screen text;
pyte needs two harness-side patches: materialize its sparse buffer rows
before IL/DL, and clamp CUU/CUD at margins only when the cursor starts
inside the region). Programs verify by wiring `TerminalProgramIO.write`
into an `AnsiParser` and asserting the grid after keystrokes.
**ONLCR lives in `NodeProgram`, not the emulator.** The screen is
deliberately xterm-faithful — bare LF is *index* (cursor down, same
column), matching pyte. A real PTY maps NL→CR-NL on output, so ink-style
inline frames (lines ending in bare `\n`) land at column 0. That
translation belongs at the PTY substitute (`NodeProgram.onlcr`), never in
`TerminalScreen` — putting it in the emulator would break the pyte
cross-check. Regression: a captured real ink frame (claude-code's
config-recovery box) must render byte-for-byte against pyte with ONLCR
applied, and shear without it.
**Terminal query replies go out through `AnsiParser.respond`.** DSR
(`ESC[6n`), DA (`ESC[c`/`ESC[>c`), and DECRQM (`ESC[?<n>$p`) are questions
a TUI asks and BLOCKS on; the answer travels back on the program's stdin.
`TerminalSession.launch` wires `parser.respond` to `program.input` (and
clears it on exit). When `respond` is nil (the pyte cross-check, static
renders) queries are consumed silently and the screen is untouched, so
the cross-check is unaffected — verify both: a program that emits the
three queries must receive the exact replies on stdin and not hang, and
the pyte cross-check must still pass.
**Keyboard input encoding lives in `TerminalKey` (pure), UIKit glue in
`ProgramKeyTextField`.** Physical special keys — arrows, Home/End, Page
keys, Insert/Delete, F1–F12, Tab/BackTab, Escape, Ctrl-combos — become
xterm byte sequences a program reads on stdin (`ESC[A`, `ESC[1;5A` with
modifiers, `ESC[15~`, DEL for Backspace, control bytes for Ctrl+letter).
`TerminalKey.encoded(_:)`/`.control(for:)` are Foundation-pure and verified
in the screen harness; `pressesBegan` maps `UIKey` → `TerminalKey` and
routes through `TerminalSession.sendSpecialKey`, and the delegate turns a
soft-keyboard backspace (empty replacement over a range) into DEL. Only
keys a running program consumes are intercepted. The arrows' form depends
on DECCKM (`ESC[?1h` → SS3 `ESC O A`, else CSI `ESC[A`), a mode the SCREEN
owns — so `sendSpecialKey` encodes with `screen.applicationCursorKeys`,
never the field. The parser also READS SS3 cursor forms (they move the
cursor like their CSI twins), which the pyte cross-check covers.
**Bracketed paste (`ESC[?2004h`) is honored, not just accepted.** When a
program enables it, `TerminalSession.sendPaste` wraps the pasted text in
`ESC[200~`…`ESC[201~` so a multi-line paste is one atomic block instead of
a burst of Enters (the agent-CLI "paste a snippet" case); off, it goes raw.
The mode lives on the screen (`bracketedPaste`), so the wrapping is decided
there and `ProgramKeyTextField.paste` just forwards the pasteboard text.
The msh LANGUAGE (`ShellLanguage.swift` + the evaluator in `Shell.swift`)
verifies against **real `/bin/sh`**: the same script corpus runs through
`shell.runProgram("sh script.sh", …)` and through `/bin/sh script.sh` in
twin scratch directories, comparing stdout and exit status. Keep the
corpus wide — control flow, functions, `$(…)`, `$((…))`, `${…}` operators,
field splitting, globs in loops, `set -e`, redirects on compounds,
`while read` from files and pipes, script/shebang execution.
The PACKAGE MANAGER (`PackageManager.swift`) verifies three ways: a semver
corpus against spec truths; `resolveTree` against real `pnpm install
--lockfile-only` (identical name@version sets, same registry); and
`install()` by running **real `node`** in the installed root and
requiring the package — the layout is correct only if Node's own
resolver agrees. Integrity (sha512/sha1) is checked before unpacking.
The NODE LAYER (`NodeEngine.swift`, needs `-lz` — its zlib module rides
libz, and CryptoKit backs crypto) verifies against **real `node`**: the
same fixture scripts run through both engines in twin directory trees,
stdout and exit status compared (console formatting, path, fs round-trips,
CommonJS + JSON + node_modules requires, EventEmitter, Buffer encodings,
argv/env/exit codes, nextTick/promise/timer ordering, async/await, util,
assert) — plus an installed bin (mkdirp) executed by our engine mutating
the real filesystem. Known divergences to keep out of fixtures: absolute
host paths in cwd, setTimeout-vs-setImmediate order from the main module,
stderr text. `uncaughtException` is honored for SYNCHRONOUS top-level
throws (handler runs → no exit 1; may `process.exit`); the async sibling
`unhandledRejection` stays unimplemented — the public JavaScriptCore API
has no rejection hook (header-audited: only `exceptionHandler` + promise
creation), so tracking it would false-positive on awaited rejections. Do
not add a `Promise.prototype.then` patch for it. Part-2 surfaces verify the same way: ESM fixtures (all
import/export forms + chalk@5, a real ESM-only package), child_process
with the harness bridge running /bin/sh (matching real node's /bin/sh
exactly; msh semantics proven separately end-to-end), and fetch/https
against a live local HTTP server. The engine runs JS on a background
queue — never block the main actor from JS; `execSync` blocks the JS
thread on a semaphore while msh runs on main.
TCP (`NodeSockets.swift` + the `net` module) verifies THREE ways, and the
third is the one that matters: twin-engine fixtures (ours vs real node,
stdout+status), our server against a REAL node client, and our client against
a REAL node server — each cross case compared byte-for-byte against the same
peer talking to real node, because "it works when both ends are ours" proves
nothing about the wire. Run the suite REPEATEDLY: every bug this layer had
was intermittent (one run in three), so a single green run is not evidence.
Load-bearing rules, each paid for:
**A socket's `'close'` means the file descriptor is gone**, not "both stream
sides finished" — `net.Socket` sets `_hostOwnsClose` and emits `'close'` from
the host event, and `emitCloseOnce` honors that. Do not let the writable
side announce a socket's close.
**`'close'` is emitted once per STREAM, not once per side** — a Duplex that
ended AND finished used to emit twice, which halves any `++done === n`
counter.
**EOF is not a close.** The peer's FIN means no more data; the fd retires
only when BOTH directions are done (`readEOF && writeShutdown`), the write
queue drained, and every byte read has reached JavaScript. Closing on EOF
loses buffered bytes and breaks half-open sockets.
**An accepted socket must never exist without a handler.** A server's
handler receives its accepted sockets' events too, tagged by socket id;
`'connection'` is necessarily the first event for a new id, so JavaScript
registers the Socket before anything else can arrive. Do not reintroduce a
placeholder-then-adopt scheme — a fast peer's bytes and FIN vanish in that
window.
Nothing may block the socket queue: `getaddrinfo` runs on a separate
concurrent queue and connect is non-blocking, or one slow host stalls every
other socket's I/O.
Known divergence, do NOT write fixtures across it: node reports a server's
`'connection'` before the connecting client's `'connect'` and we report the
reverse (a loopback handshake completes inside `connect()`; the accept is a
dispatch-source event). Deferring delivery does not reorder it. Assert each
socket's OWN event sequence instead. Likewise `server.getConnections()`
mid-exchange is nondeterministic in real node (1, 2 or 3 across runs).
`dns` rides the socket layer's `getaddrinfo` (on the resolver queue, never the
I/O queue). Fixture it ONLY on cases node and getaddrinfo agree on by
construction — IP literals and hosts-file names — because node's `resolve4`
queries a DNS server through c-ares and never reads the hosts file. Record
types getaddrinfo cannot answer must keep saying so rather than returning an
empty list.
Real-package proofs that must keep working (each found bugs no fixture did):
express (http server), ws in both directions (upgrade + framing), chokidar (the
watcher every dev tool uses), and **`tsc --watch`** — TypeScript's compiler in
watch mode must compile, detect an edit through our watcher, recompile, and
report the same diagnostics as real node. That last one is the phase-D loop
(edit → recompile → diagnostics) and the heaviest consumer of `fs.watch` there
is; if it breaks, suspect the watcher or `Stats` before suspecting tsc.
RSA (`NodeKeys.swift`) rides Security framework's `SecKey`, which speaks PKCS#1
while node speaks PKCS#8/SPKI — the DER reader/writer there exists ONLY for that
unwrap and rewrap, and it must keep returning nil on malformed input rather than
guessing. PKCS1v15 signatures are deterministic, so the cross-engine test also
checks that re-signing with the OTHER engine's imported key gives identical
bytes; that is what proves the DER round trip, not just the signature. Generated
keys must NOT be persisted to the keychain (`kSecAttrIsPermanent: false`) — a
program's key should not outlive the program. `privateEncrypt`/`publicDecrypt`
stay refused: SecKey encrypts with the public key and decrypts with the private
one, and sign/verify is the private-key direction.
SIGNING (ECDSA P-256/384/521 and Ed25519, via CryptoKit) cannot be verified by
comparing bytes — signatures are randomized. The test is CROSS-ENGINE: real node
must verify our signatures and we must verify node's, for every key type, with a
tampered message rejected. Keep `jsonwebtoken` green too (RS256, PS256, ES256 and HS256, signed
in one engine and verified in the other) — it exercised three faults no fixture
did. Ed25519 signs the MESSAGE (a digest name is an error, code
`ERR_OSSL_INVALID_DIGEST`), and `dsaEncoding: 'ieee-p1363'` selects JOSE's raw
r||s over the DER default. RSA refuses: node generates a key where we cannot, so
assert that on OUR side alone, never as a twin fixture.
**Digest names arrive in OpenSSL's legacy forms** — `jwa` signs ES256 by asking
for `RSA-SHA256`, certificates use `ecdsa-with-SHA256`. Normalize the prefix;
node accepts them for any key type.
**Buffer's base64 decoder must accept the base64URL alphabet** (`-` and `_`
translated, not stripped). node's is lenient and real code depends on it: `jwa`
hands a base64url signature straight to `Buffer.from(s, 'base64')`. Stripping
those characters drops bytes SILENTLY, and the symptom appears far away.
**KeyObjects are legal wherever key material is** — `createHmac`, `createCipheriv`
and the signers must all accept one. `jsonwebtoken` wraps its secret with
`createSecretKey`, so a plain `String(data)` coercion hashes `"[object Object]"`.
CIPHERS verify two ways, and the second is the one that matters: with a FIXED
key and IV the ciphertext, auth tag and derived keys must be byte-identical to
real node's (a much stronger check than "it round-trips"), and cross-engine —
what we seal real node must open, and what node seals we must open, AAD
included, with a wrong AAD rejected. AEAD modes ride CryptoKit; CBC/CTR/ECB ride
CommonCrypto, the only system API that exposes them. A Cipher produces its bytes
at `final()`, not in `update()`, because an auth tag cannot exist before the last
byte — do not "fix" that into incremental output. The asymmetric family
(sign/verify, key generation, key parsing, ECDH, DH, RSA) REFUSES with its reason
named; it needs SecKey and ASN.1 work, and a half-implementation would be worse.
`crypto.subtle` stays ABSENT, not refusing: it is an object, so a library that
feature-detects it would use it and fail, where absence makes it take its
fallback.
**Audit core-module surfaces against real node periodically** — list
`Object.keys(require(m))` in both engines and diff. It is how the `URL`,
`Buffer`-statics and `Stats.mode` bugs were found, and each was a member that
existed-but-answered-wrongly or was absent while a package quietly concluded
something false. When a member cannot be supported, make it REFUSE with the
reason rather than leaving it absent or faking it (`fs.glob`, the privilege
setters, brotli/zstd).
**`URL` is ours, and everything HTTP parses through it** — JSC exposes none, so
the bootstrap's class is the real one. Relative resolution must follow RFC 3986
§5.2: protocol-relative, origin-relative, query-only, fragment-only, and
dot-segment removal over the MERGED path. Do not reintroduce "trim the base
after the last slash" — it turned `new URL('/root', 'https://x/a/b')` into
`https://x/a//root` and never resolved `../`. Credentials stay in `href` and
stay OUT of `origin` (measured).
`fs.watch` (`NodeWatch.swift`) is kqueue through `DispatchSource`: a watch per
subdirectory for recursive mode, and a watch per FILE inside a watched
directory — that per-file watch is the only way kqueue can NAME a modification
(it reports that a directory changed, never which entry), so do not "optimize"
it away. Descriptors are capped per watcher; past the cap a directory reports
its own change instead. Verification is deliberately shaped around the fact
that watch events are the most platform-dependent surface in node (macOS =
FSEvents, Linux = inotify): compare which PATHS are reported and in what order
for a DIRECTORY watch, normalizing event types and collapsing consecutive
duplicates ON BOTH SIDES (real node emits duplicates too); compare a root FILE
watch strictly. Do not try to match node's first directory event — on macOS it
reports activity from before the watch existed, and faking that would mean
inventing an event. Keep the real-package proof green: chokidar must report the
same adds/changes/unlinks/nested paths as under real node.
**`fs.Stats` must carry node's full field set**, from `lstat(2)`: mode, uid,
gid, ino, dev, nlink, rdev, blocks, blksize and all four timestamps in Ms and
Date form. This is not cosmetic — chokidar gates every entry on
`4 & parseInt(stats.mode, 10)`, so a missing `mode` read as NaN, meaning "not
readable", and silently hid every FILE in a watched tree while directories came
through. `lstat` must not follow links (and `isSymbolicLink()` must be able to
return true).
The HTTP CLIENT is TWO transports and the split is deliberate: plaintext
`http.request` rides `net` (so response bodies arrive incrementally, request
bodies can stream, and a 101 hands the socket over — the WebSocket path),
while `https.request` stays on URLSession because TLS is a handshake we cannot
put on a raw socket. Verify the client the same way as the server: a neutral
raw-socket sink prints what it received and our request BYTES must equal
node's per request (normalize the Host port; split the stream into requests).
Do NOT compare packet boundaries or connection reuse — node's agent pools
sockets and sends several requests down one connection, we open one per
request. That is a recorded divergence, not a bug; pooling is future work.
**`socket.cork()`/`uncork()` and `_readableState`/`_writableState` are
load-bearing for real packages.** `ws` corks around every frame (without cork
a WebSocket send throws) and reads `socket._readableState.endEmitted` /
`receiver._writableState.finished` to finish a closing handshake (without them
messages flow but `'close'` never fires). The state objects are LIVE VIEWS
over the fields the streams already keep — keep them that way rather than
storing a second copy that can drift. Regression: the real `ws` package must
work in BOTH directions against real node as the peer, closing handshake
included.
The HTTP SERVER (`http.createServer`, in the engine's http module) verifies at
the WIRE, not through its API: one raw-socket client sends literal request
strings and prints the exact response bytes (normalizing `Date`), and those
bytes must be IDENTICAL against our server and real node's, across keep-alive,
pipelining, HEAD, 204, HTTP/1.0, chunked request bodies, duplicate headers and
`Connection: close`. Four framing rules were measured and are easy to break:
user headers keep insertion order, then `Date`, then `Connection`/`Keep-Alive`,
then framing; `res.end(body)` with nothing written yet sends Content-Length,
not chunked; `writeHead()` COMMITS the framing (so `writeHead` + `end(body)`
is chunked); and 204/304/1xx get no framing header while HTTP/1.0 is framed by
the close. Also keep the real-package proof green: express installed by our own
PackageManager, served by our engine, answering real node's client identically.
`https.createServer` refuses on purpose (no TLS handshake on a raw socket) —
a DELIBERATE divergence from node, which creates a server that fails later, so
it must not be a twin fixture.
**Buffer's statics must stay ENUMERABLE**, and all four allocators
(`from`/`alloc`/`allocUnsafe`/`allocUnsafeSlow`) must exist. `safe-buffer` —
under express, body-parser and hundreds more — copies them with
`for (key in src)` and only re-exports the real module when all four are
present. Class statics are non-enumerable, which silently produced a Buffer
with no `isBuffer` INSIDE those packages while every direct test passed. Do
not convert them back to `static` members.
The T↔G JOIN (`NodeProgram` + the engine's TTY surface) verifies like any
terminal program — `TerminalProgramIO.write` → `AnsiParser`, grid asserted
after keystrokes, pumping the main runloop between steps — covering both
^C disciplines (cooked = SIGINT, raw = byte), stdin liveness (a waiting
listener holds the event loop open), resize events, alt-screen
enter/restore, and transcript stripping; PLUS end-to-end through
`MouseShell.runProgram` with a `launchProgram` context: an interactive
`node tui.js` must hand over a `NodeProgram`, a mid-pipeline `node` must
stay headless. Line-splitting and escape-stripping are unicode-scalar
level on purpose: CRLF is one Character to Swift (the same grapheme trap
the pyte pass caught in the parser).

Android (`kotlin/`): `cd kotlin && ANDROID_HOME=~/Library/Android/sdk
./gradlew assembleDebug`. Standard Gradle project — Android Studio opens
the `kotlin/` folder directly. It's a full parity app (Compose), not a
seed: mirror any iOS feature change here too, or note in the PR why not.
The two apps share no code (no cross-platform bridge) — parity is by
faithful re-implementation, file-for-file where it helps
(`Shell.swift`↔`MouseShell.kt`, `CarouselDeck.swift`↔`Model.kt`, etc.).
**Phases T, F and G (terminal screen, package manager, Node layer) are
iOS-only by a recorded decision, not an oversight** — see "Android parity"
in system.md for the measured split (the Node engine is 72 % portable JS
bootstrap, 28 % host bridge) and why WebView + `@JavascriptInterface` is the
parity path that keeps invariant #4. It is a scope decision with a stated
trigger; don't fix it in passing.

## Invariants

1. **The gesture law.** One-finger horizontal drags + all two-finger gestures
   belong to the shell, everywhere. Content gets taps, vertical scrolling,
   and the keyboard. Refinement: while the editor is focused
   (`deck.editorFocused`), *every* drag on that container belongs to the text
   — selection handles and caret drags must never drive the lane
   (`CarouselLane.swipe` gates on it; breaking this pegs the CPU and swaps
   containers mid-selection).
2. **Identity registries, main-thread only.** One `Workspace` per repo
   (`Workspace.byRepo`), one `FileBuffer` per (workspace, file)
   (`FileBuffer.byFile`), one shared `ContainerContent` per synced kind
   (`ContainerContent.sharedByKind`). All are `nonisolated(unsafe)` static
   dictionaries touched only from the main thread — follow the existing
   pattern; do not introduce actors or locks around them piecemeal.
3. **Container-identity rendering.** The visible panel set renders through a
   `ForEach` keyed on **container id** with one uniform modifier chain
   (`CarouselLane`). A commit moves the same view instance to a new offset.
   Keying by slot/position reintroduces the unload flash.
4. **Zero third-party dependencies** until the roadmap says otherwise.
5. **Native per platform, no bridges.** Two apps: `swift/` (iOS/iPadOS) and
   `kotlin/` (Android) — each built natively against its own platform. No
   web builds, no Capacitor/React Native/Flutter; that direction was removed
   deliberately. Big feature directions live on product branches (`vs-code`,
   `cursor`, `n8n`, … — see ROADMAP.md), and slices merge to `main` when
   feel-tested.

## Landmines — do not "fix" these

- `ForegroundView` measures with **`containerRelativeFrame`**. Replacing it
  with `GeometryReader` breaks lane layout: the oversized ASCII background
  sibling inflates the reported size. The comment in the file is not
  decorative.
- **`KeyboardFloatingHost`** (`MouseApp.swift`) sets
  `safeAreaRegions = .container` on a bridged `UIHostingController`. This is
  the *only* working way to keep the keyboard from shifting the app, because
  `containerRelativeFrame` measures the window container, which the keyboard
  shrinks at the source — `ignoresSafeArea(.keyboard)` cannot reach it.
- **`TerminalPromptField`** returns `false` from `textFieldShouldReturn` so
  the keyboard never dips between commands. SwiftUI's `TextField` always
  resigns on submit; that's why it's UIKit.
- **`FileBuffer.suppressNextChange`**: programmatic text loads must not mark
  files modified (viewing a file once queued it for commit). Set it before
  any non-user assignment to `text`.
- **`FileBuffer.ensure`** deliberately *discards* dirty text when a pull
  bumped `treeVersion` — flushing first would overwrite the freshly pulled
  file with stale text. The pull UI already warned the user.
- Terminal scrollback uses **`defaultScrollAnchor(.bottom)`** — manual
  `scrollTo` against not-yet-wrapped lines parks output offscreen.
- The ASCII backdrop's `TimelineView(.animation)` is intentionally off
  (`animateBackground = false`) — it redraws every frame and pins the CPU.

## Swift 6 concurrency house style

- Target is Swift 6 strict concurrency. For objects that need a debounced
  main-thread hop (autosave), the pattern is
  `final class X: @unchecked Sendable` (documented main-thread-only) with
  `Task { @MainActor in … }` — **not** `@MainActor` classes with
  `nonisolated init` + `MainActor.assumeIsolated`, which cascades into
  "sending self" errors in the restore paths. This was tried; it fights back.
- App-global singletons follow `GitHubAuth`: `@MainActor @Observable final
  class` with `static let shared`.
- `TerminalSession` and `MouseShell` are `@MainActor` (not the FileBuffer
  `@unchecked Sendable` pattern): they're inherently UI-thread state and run
  async streaming commands, so main-actor isolation is correct and avoids
  sending app types into the run `Task`. Background socket I/O is isolated in
  `ICMPPinger` (`@unchecked Sendable`, `DispatchQueue` + continuations
  returning Sendable values) — the one place that leaves the main actor.

## Persistence discipline

`StripPersistence` snapshots the live model into plain Codable DTOs.
Aliasing (shared content, shared workspaces) does not round-trip through
Codable — shared things are stored once and re-linked through their
registries on restore, in registry-first order. When you add model state:
add a DTO field (optional, so old saves still decode), snapshot it, restore
it, and force-quit-relaunch to prove it.

## Process rules

- **Experiment freely; merge carefully.** Branches are cheap — spike ideas,
  add throwaway UI, wire up diagnostics, keep whole experimental directions
  alive on their own branches (`swift/shared-buffer-experiments` is the
  pattern). What guards quality is the bar at `main`, not a ban on
  exploring.
- **`main` merges are feel-tested, not just build-tested.** This is a
  gesture app: before anything merges, it gets exercised on a real device
  for feel — gesture latency, spring weight, keyboard behavior, the gesture
  matrix around the change — and for function (including force-quit →
  relaunch when model state changed). "Builds and looks right in the
  simulator" is the start, not the bar.
- **What lands in `main` is clean.** Temporary NSLogs, auto-performed
  gestures, UI-test drivers, seeded fixtures — great while exploring, gone
  before merge. (A leftover auto-swipe once shipped a haunted onboarding
  ring.)
- **No explanatory microcopy.** User-facing copy (help text, labels,
  chips) states the thing, never explains or reassures about the thing.
  `sudo <cmd>` — not `sudo <cmd> (you already are the only user)`;
  `ps / top` — not `ps / top (top is live: q quits)`. Command syntax
  (`[-la]`, `<file…>`, `(!!, !N)`) is content; parenthetical asides are
  not. Never add such copy unless explicitly asked. Rationale lives in
  code comments and docs, not in the UI.
- **Show, don't just describe.** Anything visible gets a screenshot or short
  clip in the PR description (GitHub hosts them). Exploration artifacts
  worth keeping — mockups, direction studies — live in `sketches/`.
- **Measure performance on device.** One known trap: with the keyboard up,
  the iOS *simulator* runs a system-owned looping A/V pipeline (software
  H.264) inside the app process — ~10 %+ constant CPU that is not real;
  devices decode in hardware. Judge CPU with the keyboard down, or on
  device.
- **Docs move with behavior**: `swift/README.md` (gestures/functionality),
  `DESIGN.md` (look/motion), `ROADMAP.md` (scope changes).

## File map

| File | Owns |
|---|---|
| `MouseApp.swift` | App entry, floating-keyboard host, tap-outside dismiss, window minimums |
| `ContentView.swift` | Backdrop + foreground composition |
| `ForegroundView.swift` | The shell: lanes, dividers, all shell gestures, ring swipes, `CarouselLane`, `Panel` |
| `CarouselDeck.swift` | Ring model: lanes/reserve, container catalog, onboarding chain, per-ring viewport (open file, terminal, editor focus) |
| `Workspace.swift` | Project truth: tree on disk, dirty set, sync state, graph cache, tarball download, native tar/gzip (`TarGz`) |
| `WorkspaceViews.swift` | Files/Viewer containers, `FileBuffer` (shared live documents) |
| `GitGraphView.swift` | The git module: commit-graph layout + rendering, history fetch, and `GitModuleToolbar` (`commit · sync · branch · merge · refresh` in the header) |
| `GitHubAuth.swift` | Device Flow, Keychain, sign-in container |
| `GitHubPush.swift` | Git Data API push (blobs → tree → commit → ref) |
| `Shell.swift` | `msh` — the from-scratch shell: AST evaluator (control flow, functions, pipelines, redirects), expansion (fields, globs, `${…}` ops, `$(…)`), ~60 built-ins incl. `git` and `sh`, and `ICMPPinger` (real ping) |
| `ShellLanguage.swift` | The msh language: lexer, AST, recursive-descent parser, `$((…))` arithmetic — pure, no I/O, no state |
| `PackageManager.swift` | Phase F: semver, npm registry client, tree resolver (classic hoisting), tarball installer (integrity-checked), `node_modules` manifest, and `TarGz` (moved from Workspace) |
| `NodeEngine.swift` | Phase G: the Node layer on JavaScriptCore — CommonJS loader over `node_modules` (main/exports/index), core modules (`fs` `path` `os` `util` `events` `buffer` …), event loop (timers/immediates/nextTick), workspace-virtual paths |
| `GitCore.swift` | The native git engine: loose objects (zlib+SHA-1), trees, commits, refs, checkout, status, DIRC index, packfile codec (with delta resolution), pkt-line, and the three-way merge engine (`merge`/`diff3`) — real-git interoperable |
| `GitRemote.swift` | The remote half: clone/fetch/push over GitHub smart-HTTP, and `POST /user/repos` auto-create on push |
| `Terminal.swift` | `TerminalSession` (engines: msh, js), JS engine, switcher chip, container, prompt field, screen-grid renderer |
| `TerminalScreen.swift` | The terminal SCREEN: VT100/xterm cell grid (cursor, scroll regions, SGR, alt screen) + `AnsiParser` — verified against pyte |
| `TerminalPrograms.swift` | `TerminalProgram` (full-screen program contract — the fork/exec-less PTY substitute) + the pager (`less`) and live `top` |
| `StripPersistence.swift` | Snapshot/restore DTOs for the whole strip |
| `AsciiArt*.swift`, `AppFont.swift` | Backdrop art, type constants |
