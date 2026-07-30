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
**`Buffer.from(arrayBuffer)` must SHARE memory, never copy** — node documents it
as a view, and every wasm interop depends on it (webpack writes into
`WebAssembly.Memory.buffer` through such a Buffer and reads the result back).
Copying makes wasm hashes return the INPUT padded with NULs: a wrong answer with
no error near it. Note the asymmetry, which is measured, not guessed:
`Buffer.from(typedArray)` copies the VALUES (each truncated to a byte), so a
`Uint16Array` of `[0x0102, 0x0304]` becomes two bytes — Uint8Array's own
constructor already does that, so leave the default path alone.
**`interface` is a reserved word in strict mode** — a JS parameter named that
compiles fine on the Swift side and breaks the bootstrap, because swiftc cannot see
into the string. Run `node --check` on the extracted bootstrap after every edit.
**In the socket layer, `nil` means SUCCESS.** `?? "EBADF"` on those returns reports
every success as a failure — coalesce to `""` instead.
**Killing a suite orphans the real-node peers it spawned**, and the next run fails
on a port they still hold. Clear strays before re-running rather than debugging a
phantom.
**A refusal must NAME A REASON and stay true; audit them when capabilities grow.**
A fixture pins the shape — every refusal has a reason, and none matches a stale
pattern ("single process", "on the roadmap", "not available yet", a bare "X is not
available"). Refusals rot silently as the engine gains abilities: `cluster` claimed
"single process" after live children landed, and http2 blamed missing HTTP support
after HTTP/1.1 was real in both directions. When you add a capability, grep the
refusals for what it makes false.
**A refusal must be TRUE, and re-checked when the surrounding capabilities grow.**
`createECDH` refused for weeks claiming it needed SecKey; CryptoKit had done ECDH
all along, and node's uncompressed-point encoding IS `x963Representation`, so
nothing needed converting. A wrong refusal is worse than a gap — it stops anyone
looking again. Verify a key agreement cross-engine: both sides must derive the
SAME secret from each other's public key.
`worker_threads` rides the same child-engine machinery as `fork`: a Worker is a
second engine plus the message channel. Shared memory is the real limit — two
JSContexts share none — so `SharedArrayBuffer` across threads,
`receiveMessageOnPort`, `get/setEnvironmentData` and `BroadcastChannel` must REFUSE
by name; an Atomics wait that never wakes is far worse than an error. When writing
a worker fixture, note that node requires the Worker path to start with `./`, and
always surface the real node peer's STDERR — a fixture that hides its error wastes
every run.
**`process.send` must be UNDEFINED without an IPC channel** — `if (process.send)`
is how a worker library asks whether it was forked, so a stub sends every one of
them down its IPC path to talk into nothing. An open channel HOLDS the child's
event loop open (node's does), and `disconnect()` gives that handle back.
**Bridge blocks: keep a `JSValue` callback in the last slot and avoid a `Bool`
before it** — `(String, [String], String, Bool, JSValue)` did not marshal through
JSC, the callback landed in the wrong argument, and the only symptom was a child
exiting 1 with no output. Pass flags as strings.
**Bootstrap code that touches `process` must sit AFTER `process` exists** — a
gated block placed earlier hit a temporal dead zone and silently killed the rest
of the bootstrap, visible only in the one configuration that took that branch.
**Use `__toBytes` for anything a caller hands you as data.** Never
`Buffer.isBuffer(x) ? x : Buffer.from(String(x))` — that stringifies a plain
`Uint8Array` into `"7,0,0,0"`, and it was in TEN writers (sockets, HTTP bodies,
ciphers, signers, child stdin, WebSocket sends, fs). Binary protocols arrive as
views, not Buffers.
**`child.unref()` must really release the handle**, like a socket's: esbuild keeps
its service alive with a ping loop and unrefs the child, so a no-op unref means a
program that finished correctly never exits — which reads as a hang long after it
started working.
**A piped child's stdio is BYTES.** latin1 is the transport in both directions (one
codepoint per byte, lossless through the String hop); UTF-8 is for a terminal and
destroys a binary protocol. `fs.write` on fd 1/2 must accept ANY `ArrayBufferView`
— Go's wasm runtime writes `Uint8Array`s, and `Buffer.isBuffer` is false for those
— and report the true byte count. `fs.read` on fd 0 must WAIT for data (answering 0
reads as EOF and ends a service instantly) and call back EXACTLY once per read.
A piped child must report `isTTY: false` even though the sink reuses the TTY
machinery, or programs take their interactive path while writing to a pipe.
**`fs.constants` is 55 entries, not 4.** Go reads `constants.O_WRONLY` directly.
A surface audit that counts `constants` as present because the KEY exists will
miss this — a present member can be an empty shell.
A NODE child from `child_process.spawn` is a SECOND NodeEngine on its own queue,
with live pipes; anything else runs through msh and reports collected output.
Verify a child with an INTERLEAVED exchange — each request depending on the
previous answer — because a collect-then-report implementation passes any
transcript that does not require interleaving. Pipes currently carry TEXT: a
binary protocol (esbuild's service) does not survive the round trip, which is the
next named gap, and `fork`'s IPC channel refuses rather than pretending.
**A "wasm package works" claim needs the package RUN, not imported.** Every such
claim made before `Buffer.from(arrayBuffer)` shared memory was against a broken
path: webpack's hashes re-earned it, esbuild-wasm did not (it needs a live child
process — see below). Loading is not running.
**WebAssembly RUNS on this engine** (JSC, interpreter mode) — wasm packages work
today; the WebView JIT would buy speed, not capability. Keep the webpack AND
esbuild-wasm proofs green: webpack bundles byte-identically and exercises wasm
hashing, module resolution and terser; esbuild-wasm runs a whole compiler in wasm
through a live child process and a binary pipe protocol, which is the sternest
test of stdio fidelity there is.
`require(".")` and `require("..")` are relative DIRECTORY requests — webpack's
Compiler.js uses the first form.
The `WebSocket` GLOBAL rides URLSession's WebSocket task — the only TLS-capable
path here — while the `ws` PACKAGE rides our own sockets for `ws://`. Keep both.
`open` must come from the delegate's handshake callback, never from a ping
round-trip: a ping races the first inbound frame, so a server that greets
instantly delivered `message` before `open`, and node always fires `open` first.
Messages arriving before the handshake callback are held and released in order —
do not remove that gate. Verify against node 22's own global against the same
`ws` server.
STREAMING responses must be verified by TIMING, not content: send events with a
delay and assert the reads are SPREAD OVER TIME in both engines. A fixture that
compares only the concatenated body passes just as happily against a transport
that buffers everything, which is how the URLSession path hid this for so long.
`fetch` settles when the HEAD arrives, not when the body finishes — that is the
point of a stream — and `Response.body` is the live stream while `text()`/`json()`
drain it once. `clone()` on a streaming body refuses (node tees; we have no tee).
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
Do NOT compare packet boundaries — those are not a contract. Connection REUSE is
now, and the fixture counts connections: four sequential requests must travel
over the same number of sockets node uses (one). Split the sink's transcript on a
request line with the METHOD spelled out — `[A-Z]+ /` also matches inside "POST"
and shreds each request into single letters, which compares equal only because
both engines get shredded identically.
**A pooling client never closes its end**, which is why the server must enforce
`keepAliveTimeout`: without it an idle keep-alive connection lives forever and
`server.close()` waits on a peer with nothing left to say. The clock is cancelled
when a request arrives, and `close()` ends connections that are idle BETWEEN
requests rather than waiting out their window. Pooled sockets are unref'd while
idle so a warm pool never holds a program open.
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

### Verifying anything concurrent

- **One green run is not evidence.** Run it 20+ times. cluster passed 4 rounds and
  failed the 5th; the underlying http bug reproduced 3 times in 20. Every
  socket-teardown bug in this layer has had a failure rate near one in three.
- **Instrumentation moves the bug.** Adding `process.stderr.write` to the worker
  turned a 3-in-20 failure into 12-for-12 green. A green run *under added logging*
  is worth nothing — it changed the timing you were trying to measure. Localize by
  A/B instead: run the same binary with one behaviour switched off (kill vs no
  kill, pooled vs `agent: false`) and compare failure RATES.
- **Never chain a build and its test in one background command and then read only
  the test's output.** A failed `swiftc` leaves the previous binary in place, the
  stale binary passes, and the suite reports ALL PASS while your new fixture never
  ran. Check the build's own output, or that the fixture's name appears in the
  results. This bit once already, the same shape as the `cd x && python` trap.
- **"A partial X is worse than none" is a hypothesis with a number attached.** Build
  the thing, run a corpus against the reference, and count. Doing that for glob
  vindicated the refusal for `path.matchesGlob` (17 disagreements in 1824 cases, all of
  them node contradicting itself) and dissolved it for `fs.glob` (exact agreement) —
  a split no amount of reading the code would have found.
- **When the reference implementation is inconsistent, refuse and say so.** Encoding
  another implementation's contradictions is not compatibility, it is a bug you now
  own — especially when the API is marked experimental and may change.
- **A caveat you reason your way to is a guess; measure it.** The previous boundary
  recorded "I/O callbacks are not trampolined" from reading the code. Testing six
  routes out of the host showed four already worked and two were broken — so the
  caveat was wrong about which half. If a limitation is worth writing down, it is
  worth one test first.
- **Cover the ROUTES, not the ones you happened to think of.** A guarantee about "every
  callback" needs a fixture per distinct path out of the host (fs, dns, watch, http,
  child, socket). The first version of the tick guarantee passed its fixture and was
  still half-true, because the fixture only exercised timers.
- **A hang is a worse bug than an error.** When a network path can fail, check that
  it produces an event a caller can act on. Two of this layer's http defects were
  silent waits, and both were invisible to fixtures that only asserted happy paths.

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
