# system.md — Mouse as a system

The umbrella spec for the `system` product branch: **turning the terminal
from a fixed set of built-ins into a place where programs live.**

This document is the entry point. Two companions hold the detail:

- **[compile.md](compile.md)** — the language-by-language compilation plan
- **[xcode.md](xcode.md)** — signing and installing native iOS apps

Written as a handoff: a fresh session should be able to read this alone and
pick up the work.

---

## 0. State of the world

**Branch:** `vs-code-features`. **Phases T (ANSI screen), A (msh
language), F (package manager), and G-core (Node layer) are BUILT and
verified** — one commit per phase, verification recorded below. The
install rule holds end-to-end for pure-JS CJS tools: `npm install <pkg>`
then `<bin>` executes on device. **Phase G part 2 landed too**: ES modules
(transpile-to-CJS), the `child_process`→msh bridge (JS calls Mouse's
native git), and `fetch`/`https` over URLSession. **The T↔G join landed
next**: `node`/`npx`/installed bins run as terminal *programs* —
`process.stdin` gets real keystrokes, raw mode or the alt screen hands the
program the phase-T grid (the ink model), cooked-mode ^C is SIGINT,
rotation is a `resize` event. **Streams are real now too** (Readable/
Writable/Duplex/Transform, pipe/pipeline/finished, async iteration, fs
streams — 8 new fixtures, 27 total matching real node). **`readline` is
real** (28 fixtures): TTY line editing over raw mode — echo, backspace,
^C→SIGINT — plus `question` in callback and promise forms, and line
splitting from any Readable. **`crypto` and `zlib` are real** (CryptoKit
digests/HMAC + the system CSPRNG; libz gzip/deflate/raw — 30 fixtures
matching real node). **Real npm packages now run** — commander@15
(pure-ESM CLI framework) and the interactive `prompts` library, end to
end, keystrokes to answer — and chasing ink exposed and fixed a layer of
engine gaps: **top-level await** (ESM evaluates under async wrappers;
imports await only genuinely-pending dependencies, real ESM's
infection), import attributes (`with {type:'json'}`), `export * as`,
require-error eviction (a failing module can't linger as partial
exports), `module.createRequire`, `require.resolve`, web globals
(TextDecoder/TextEncoder/atob/btoa/URL), and a sync-backed
`WebAssembly.instantiate` (JSC's async wasm never settles on a bare
JSContext) — the yoga-layout wasm engine compiles and runs. **INK RUNS**:
React 19 + react-reconciler + yoga-wasm render real frames, keystrokes
re-render through React onto the phase-T grid, `useApp().exit()` ends
the program — the ink-style TUI milestone, the shape of Claude Code's
UI, real on our engine. 32 fixtures matching real node (v22), 47
TTY-harness assertions. **The claude-code chase produced two findings
and a breadth boundary.** Finding 1: claude-code 2.x is NATIVE (a
Bun-compiled per-platform binary; the npm package is an installer) — no
JS engine anywhere can run it, so the roadmap target is claude-code
1.0.128, the last JS build. Finding 2: that 9.3 MB minified bundle now
FULLY PARSES AND LOADS through our engine — the chase filled the API
tail (below) — and startup currently stops at one dangling top-level
await (exit 13, the honest signal), the next thing to hunt. **THE
DANGLE IS FOUND AND CLEARED — claude-code 1.0.128 now renders its
interactive UI through our engine**: a bordered, ANSI-colored ink prompt
box, `stdin.setRawMode(true)`, listening for keypresses. Startup runs
its full init chain; what remains is the live REPL, which keeps the
process alive on a TTY exactly as it should. **The ~40 s transpile cost
is FIXED** — the ESM→CJS rewrite was O(n²) (firstMatch + full-string copy
per statement); a single-pass all-matches rebuild is 31× faster (40.8 s →
1.3 s on the 9.3 MB bundle), byte-identical output. **Next:** drive the UI
through the phase-T grid on device, then phase B (WebView JIT) for raw JS
speed. Unhandled-rejection exit codes are parked, with the reason
recorded below. **A real claude-code ink frame now renders aligned on the
phase-T screen** — the config-recovery dialog, a clean bordered box —
after adding ONLCR (NL→CR-NL) at the NodeProgram PTY boundary; without it
ink's bare-`\n` frames sheared diagonally. **The terminal now ANSWERS
queries too** (DSR/DA/DECRQM via `AnsiParser.respond` → the program's
stdin), so a TUI that probes cursor position or feature support gets its
reply instead of hanging. **And the input leg is encoded** (`TerminalKey`
+ `ProgramKeyTextField`): hardware arrows/Home/End/F-keys/Ctrl-combos and
soft-keyboard backspace become the xterm byte sequences a program reads,
so a TUI navigates and edits.

### Shipped and verified this cycle

| Area | What landed |
|---|---|
| **Merge engine** | `GitCore.merge` — fast-forward, three-way with two-parent commit, diff3 conflict markers. A `diff3` bug (one-sided edits produced false conflicts) was fixed by comparing each side against the **base** chunk, not against each other |
| **Git module toolbar** | `commit · sync · branch · merge · refresh` in the Graph container header. Controls pre-exist and dim to 0.28 opacity until usable; a tap on a dimmed control explains itself in the terminal |
| **Fetch** | Now a *true* fetch: objects land in the store, only `refs/remotes/origin/<branch>` moves. `have` negotiation makes packs incremental |
| **`git pull`** | Terminal-only, explicit. Refuses over uncommitted edits. **Sync deliberately does not pull** — the app must never rewrite a user's files on its own |
| **Auth** | Migrated GitHub App → classic **OAuth App** (`Ov23liZpd88m5S0nz1ZS`, `repo` scope). GitHub App provider and all refresh-token machinery removed |
| **Terminal** | `uname df free uptime ps top ip/ifconfig chmod ls -l/-la lsb_release`, muscle-memory aliases (`less`→cat, `nano`→viewer, `sudo`→passthrough), and honest refusals for `apt`/`kill`/`ss`/`systemctl`/`chown`/`passwd` |
| **Android** | Pixel-only ring travel moved to the **negative space between containers** (`systemGestureExclusion` is capped at 200 dp, so edge strips lose to the back gesture on Pixels) |
| **Phase T — the terminal screen** | `TerminalScreen.swift`: VT100/xterm grid (cursor, scroll regions, IL/DL/ICH/DCH/ECH, SGR incl. 256/truecolor, alt screen) + byte-at-a-time `AnsiParser`. `TerminalPrograms.swift`: the `TerminalProgram` contract — a full-screen program owns screen + keyboard, the fork/exec-less stand-in for a foreground process on a PTY — plus the first two real programs: `less`/`more` (true pager) and live `top`. `Terminal.swift` hosts programs (grid renderer, key routing, resize-as-SIGWINCH). **Android parity deferred** — the Kotlin terminal is transcript-only until this is mirrored |
| **The T↔G join — Node on a TTY** | `NodeProgram` (`TerminalPrograms.swift`): `node`/`npx`/installed bins launched interactively become terminal programs. `process.stdin.isTTY` is true, keystrokes arrive as `data` events, stdin listeners keep the event loop alive (node's ref'd-stdin rule). The program picks its mode like on a real terminal: plain printing stays in the scrollback (lines land ANSI-stripped, stderr keeps its color); `setRawMode(true)` or the alt screen hands it the grid — the ink model. Terminal discipline is real: cooked-mode ^C is SIGINT (handlers run, or the program dies 130), raw-mode ^C is a byte the program reads; rotation emits `resize` with the live geometry, and a program is born knowing `stdout.columns` |

### Verification performed

All against real tooling, per [AGENTS.md](AGENTS.md):

- `diff3` vs `git merge-file` — 9 cases (non-overlapping, same-line conflict,
  identical change, insert, delete, adjacent, overlap) — all match
- Three-way merge vs a real repo — `fsck` clean, both parents present,
  byte-identical content
- Fast-forward / conflict / up-to-date paths — all pass
- Fetch protocol vs `git upload-pack --stateless-rpc` — want/have body
  accepted, ACK/NAK preamble demuxed, incremental pack (6 objects) smaller
  than full closure (9)
- New shell builtins — headless harness, real device facts asserted
- **Terminal screen vs pyte** (a known-good emulator): identical final
  screen text on 17 structured + 1000 seeded-random escape streams, plus a
  ~60-assertion xterm-semantics corpus. Five real bugs found and fixed by
  this pass: Swift grapheme segmentation fused `\r\n` into one Character
  the parser matched as neither control; `ESC M` didn't scroll at the
  region top; DECSTBM homed to the region top instead of absolute (1,1);
  a pending-wrap cursor (column == width) crashed ICH/DCH; IL/DL kept the
  column instead of homing to column 1, and CUU/CUD ignored margins.
  (pyte itself needed two harness-side patches — sparse-buffer
  materialization before IL/DL, and margin clamping only when the cursor
  starts inside the region; documented in AGENTS.md)
- Pager and top programs — keys fed through `TerminalProgram.input`, grid
  asserted after every action (paging, wrap, resize, quit, ^C)
- **msh language vs `/bin/sh`** — 25-script corpus, stdout + exit status
  identical (phase A)
- **Package manager (phase F)** — semver corpus; resolution identical to
  `pnpm install --lockfile-only` on left-pad/mkdirp/debug/chalk/glob
  (1–11 package trees); installed layout proven by **real `node`**
  requiring chalk and glob from our `node_modules`; sha512 integrity
  verified before unpacking. `npm install` / `pnpm` / `npx` work in the
  terminal today
- **Node layer (phase G, core)** — 15 fixture scripts byte-identical to
  real `node` (stdout + exit status): modules, fs, Buffer, events, timers
  ordering incl. nextTick-before-promises, async/await, util, assert.
  End-to-end through msh: `npm install mkdirp && mkdirp deep/nested/dir`
  runs the installed JavaScript bin and the directories appear; `node
  file.js`, `node -e`, `npx <pkg>`, and `#!/usr/bin/env node` shebangs all
  execute
- **Node layer part 2** — the engine moved to a background queue (JS never
  blocks the UI thread), enabling: **`child_process`→msh** (`execSync`/
  `exec`/`spawnSync`/`spawn` run msh builtins — JS calling `git status`
  gets Mouse's native git; verified with the bridge running /bin/sh
  against real node's /bin/sh, byte-identical), **ES modules** (transpiled
  to CJS at load: all import/export statement forms, dynamic `import()`,
  `import.meta.url`, package.json `type`, `exports` incl. conditions,
  `#imports` — proven by chalk@5, an ESM-only package, matching real node
  byte-for-byte), and **`fetch` + `http`/`https`.get/request** over
  URLSession (verified against a live local HTTP server, both engines).
  19 fixtures total, all matching. Remaining gaps (honest): `net`, the
  WebView JIT surface (phase B) for speed, and unhandled promise
  rejections don't exit(1) — that one is PARKED, not pending: JSC's
  rejection tracker (`JSGlobalContextSetUnhandledRejectionCallback`) is
  private API, and the public-surface workaround — patching
  `Promise.prototype.then` — cannot see `await`'s internal
  PerformPromiseThen, so every awaited rejection would look unhandled and
  exit healthy programs. A wrong exit code is worse than a missing one;
  revisit only if the API goes public or phase B's WebView engine offers
  a hook
- **Stream depth** — the `stream` sketch became the real thing: Readable
  with paused-vs-flowing modes, an internal buffer, `_read` pull,
  `'readable'`, async iteration, and `Readable.from`; Writable with
  `_write`/`_final`, drain, and write-after-end errors; Duplex/Transform/
  PassThrough (writable methods grafted onto the Readable ancestry — JS
  has one prototype chain); `pipe` with backpressure (pause on a false
  `write`, resume on `'drain'`); `finished` + `pipeline` in callback and
  promise forms (`stream/promises`); and `fs.createReadStream`/
  `createWriteStream` riding those classes (64 KiB chunks through the
  event loop). 8 new fixtures byte-identical to real node — readable
  modes, custom writables with `final`, transform+flush pipe chains,
  pipeline clean and error paths, promises form, for-await iteration, and
  an fs write-then-read-stream round trip — 27 fixtures total, all
  matching; TTY harness and sh corpus stay green
- **readline** — the stub became the module question-style CLIs need:
  `createInterface` over any Readable (non-TTY input splits lines as they
  flow — fixture vs real node reading a file stream, byte-identical, 28
  total), and on a TTY it takes raw mode and provides the cooked-mode
  discipline itself: echo, backspace editing, CRLF handling, ^C emits
  `SIGINT` on the interface (no listener → exit 130), `question` in
  callback and promise (`readline/promises`) forms, `prompt`/`setPrompt`/
  `write`/`close`, and the cursor helpers (`cursorTo`, `moveCursor`,
  `clearLine`, `clearScreenDown`) writing real CSI. Verified interactively
  through the TTY harness: a `question` flow with echoed keystrokes and a
  backspace correction lands the edited answer on the grid, the promises
  form resolves, and ^C without a listener ends the program
- **crypto + zlib** — the last two everyday stubs became real. `crypto`
  rides CryptoKit: `createHash` (md5/sha1/sha256/sha384/sha512) and
  `createHmac` with incremental `update` and hex/base64 digests,
  `randomBytes` (+callback form) and `randomFillSync` on the system
  CSPRNG, `randomUUID`, `randomInt`, `timingSafeEqual`. `zlib` rides libz
  (already linked for GitCore's packfile inflate): gzip/deflate/raw
  deflate-inflate in sync, callback, and Transform-stream forms, with
  auto-detecting inflate (windowBits 15+32) behind gunzip/inflate/unzip.
  Digest fixtures are byte-comparable across engines and match real node
  exactly; compression verifies by round trip, gzip magic bytes, and a
  gzip→gunzip pipe chain — 30 fixtures total, all matching. NodeEngine
  now imports CryptoKit + zlib, so headless harness builds add `-lz`
- **Real-package proof** — the honest discovery method: install genuine
  npm packages through our own PackageManager and run them, fixing what
  breaks. commander@15 (pure ESM, `"type": "module"`) parses and runs a
  CLI byte-identical to real node v22 through `require()`. The
  interactive `prompts` library runs END TO END in the TTY harness:
  installed on the spot, takes raw mode, its real keypress consumer gets
  parsed `(str, key)` events (readline.emitKeypressEvents is now a real
  byte→keypress parser: printables, ctrl-letters, the CSI key set), and
  the typed answer — with a backspace-free "bob" — lands on the grid.
  Engine gaps found and fixed by the chase toward ink: THREE transpiler
  holes (trailing-comment `export {…}; //`, `export * as name from`,
  import attributes `with {type:'json'}`); require-error semantics (a
  module throwing mid-evaluation is now evicted and rethrown in the
  requiring frame via a JS-side trampoline — it used to linger as partial
  exports with the error dissolving at the native boundary); TOP-LEVEL
  AWAIT (every ESM module now evaluates under an async wrapper whose
  imports await only genuinely-pending dependencies — sync modules run
  sync, `module.__esmDone` inspected the moment the call returns, so CJS
  `require(esm)` still gets exports synchronously; a TLA module suspends
  its importers exactly like real ESM; the entry's promise keeps the
  event loop alive, exit 13 if it can never settle, node's code);
  `module.createRequire` + `require.resolve` + `import.meta.resolve`;
  fs accepting `file://` URLs; web globals (TextDecoder/TextEncoder/
  atob/btoa/minimal URL, Buffer latin1/binary); and WebAssembly.
  instantiate/compile re-backed by the SYNC wasm constructors (JSC's
  async wasm promises never settle on a bare JSContext — no runloop).
  The yoga-layout Emscripten wasm binary now instantiates and returns
  its 35-export API through our engine. Verified: 32 fixtures matching
  real node v22 (new: esm-tla — TLA entry + infected import + dynamic
  import + attributes; commander-cli end-to-end from our installed
  tree), 42 TTY assertions, e2e-through-msh, sh corpus, Swift 6 build
- **INK RENDERS AND RUNS INTERACTIVELY** — the phase-G milestone. The
  remaining walls, each found by running the real package: `export *
  from` re-export must EXCLUDE `default`/`__esModule` (spec semantics —
  yoga's `export * from './YGEnums.js'` was clobbering its default
  export, which is why Node/Config vanished on one path);
  `console.Console` (ink's patchConsole builds one over its own
  streams); a `performance` polyfill (React's commit timing);
  EventEmitter's missing surface (`setMaxListeners`, `prependListener`,
  `eventNames`, static `once`); `addListener` aliases on the stdio
  shims; and stdin's paused-mode contract — ink v6 reads keys via
  `'readable'` + `read()`, so a host keystroke now fills the buffer and
  pokes `'readable'` when no `'data'` listener is flowing. End-to-end in
  the TTY harness (47 assertions total): ink + react@19 installed by our
  own PackageManager on the spot, `useInput`/`useApp` app launched as a
  NodeProgram — first frame reaches the scrollback (raw mode flips after
  mount, the two-mode model working as designed), a keypress re-renders
  through React onto the grid, `q` exits via `useApp().exit()`. One
  step from an agent CLI's UI: `npx @anthropic-ai/claude-code` is now an
  API-breadth question, not an architecture question
- **The claude-code breadth boundary** — running the real 9.3 MB
  claude-code 1.0.128 bundle head-on. Transpiler: minified-bundle forms
  (`import{x as y}from"m"` with zero spaces, `$` in identifiers,
  statements mid-line after `;`/`}` via lookbehind anchors, the bare
  export clause at EOF). New core modules: `net` (real isIP helpers;
  sockets/servers carry the sandbox's truth), `tls`, `dns`, `http2`
  (real constants), `timers` + `timers/promises`, `path/posix` +
  `path/win32`, `worker_threads`, `async_hooks` (a real synchronous
  AsyncLocalStorage), `v8`, `vm`, `perf_hooks`, `inspector`, `dgram`,
  `cluster`, `diagnostics_channel` (real pub/sub), `domain`, `console`
  (as a module), `util/types`. util grew `debuglog`/`callbackify`/
  `stripVTControlCharacters`; os grew `constants.signals`; buffer grew
  `SlowBuffer`/`kMaxLength`; http grew the extendable class surface
  (Agent, IncomingMessage, ClientRequest…, STATUS_CODES); process grew
  execArgv/execPath/getuid/umask and friends. Web globals: Event,
  EventTarget, CustomEvent, MessageChannel, AbortController/AbortSignal
  (timeout/any), DOMException, structuredClone, URLSearchParams, URL
  gained searchParams/canParse, and queue-backed WHATWG
  ReadableStream/WritableStream/TransformStream (tee, pipeThrough,
  async iteration). All 32 fixtures + 47 TTY assertions + e2e + sh
  corpus stay green; Swift 6 build passes. Startup now runs the entire
  module graph and stops at ONE dangling top-level await — exit 13, no
  crash — the open lead. (Also noted: the transpiler's regex passes take
  ~40 s on a 9.3 MB bundle — fixed in a later boundary, see below.)
- **claude-code renders its UI** — the dangle traced (marker-injection
  into a copy of the bundle, then a `.catch` on the entry promise) to a
  chain of missing Node surface, each a real correctness gap: EventEmitter
  now THROWS on an unhandled `'error'` (node semantics — an unhandled
  error used to dissolve, and any awaited event dangled); `process` grew
  the full event API (`on`/`once`/`prependListener`/`removeAllListeners`/
  `listeners`/`eventNames`/`emit` over a real registry, not just signals);
  timers return Timeout OBJECTS (`.unref`/`.ref`/`.refresh`/`.close`,
  primitive-coercible) instead of bare ids — watchdog `.unref()` was the
  wall; and `fs` grew the sync fd API (`openSync`/`writeSync`/`readSync`/
  `closeSync`/`fstatSync`, fd 1/2 → stdio). With those, cli.js runs its
  whole init chain and paints an ink prompt — bordered box, 256-color
  SGR, raw mode, stdin `'readable'` listeners — the actual Claude Code
  UI, drawn by the real published bundle on our JSC engine. 35 fixtures
  matching real node v22 (new: events-error-throw, timer-objects,
  fs-fd-sync), 47 TTY assertions, e2e, sh corpus, Swift 6 build — all
  green. What's left is live-driving that UI on the phase-T grid and the
  transpile-speed pass
- **Transpile speed: 31× (40.8 s → 1.3 s)** — the ESM→CJS rewriter's
  `replace` helper was O(n²): a `firstMatch` + `NSString.replacingCharacters`
  loop that recopied and rescanned the ENTIRE source once per matched
  statement. On the 9.3 MB claude-code bundle (hundreds of import/export
  sites) that was ~41 s. Rewritten as one pass per pattern — collect every
  match against the current text, rebuild the string once — since matches
  are statement-anchored/non-overlapping and no replacement introduces new
  import/export syntax. Correctness proven the strong way: the transpiled
  bundle is BYTE-IDENTICAL to the old loop's output (diff clean, 9,342,939
  bytes), so runtime behavior cannot change; all 35 fixtures still match
  real node, TTY/e2e/sh green, Swift 6 build passes. This is what makes
  running a real bundled CLI on device practical rather than a 40 s stall
- **Unhandled-rejection exit codes — parking now EMPIRICALLY confirmed,
  not just reasoned.** Tested directly in a bare JSContext: `await p`
  triggers a patched `Promise.prototype.then` ZERO times (JSC uses the
  internal PerformPromiseThen), and neither `reportUnhandledRejection` nor
  `onunhandledrejection` is exposed. So the only userland tracker — a
  then/catch patch — cannot see await-handled rejections and would
  false-positive on every `await` in a try/catch, killing healthy
  programs. Correct tracking needs JSC's private
  `JSGlobalContextSetUnhandledRejectionCallback` — and a public-header
  audit now confirms it: `JSContext.h`/`JSContextRef.h`/`JSObjectRef.h`/
  `JSValue.h` expose only `exceptionHandler` (synchronous throws) and
  promise *creation* (`JSObjectMakeDeferredPromise`), NO rejection hook.
  So the async half is impossible with the public API, doubly confirmed
  (behavior test + header audit). Stays parked until that API is public or
  phase B's WebView engine offers a hook. (The ESM entry promise's
  rejection IS handled — exit 1 — so the common "async main throws" case is
  already correct; it's arbitrary mid-graph promises that can't be tracked.)
- **`uncaughtException` — the synchronous half, done correctly.** The
  async rejection hook is unavailable, but SYNCHRONOUS uncaught exceptions
  ARE visible (via `exceptionHandler`), so the `process.on('uncaughtException')`
  path is implementable and now matches real node exactly. A top-level
  throw routes through `__mouseEmitUncaught`: an installed handler runs and
  the process does NOT exit 1 (it may itself `process.exit`, which the exit
  bridge records); no handler → exit 1, unchanged. Three fixtures
  byte-identical to real node v22: handler prints and the process exits 0
  (code after the throw never runs), handler calls `process.exit(42)` →
  exit 42, and the no-handler throw still exits 1. 37 node fixtures total,
  56 TTY assertions, e2e, sh corpus, Swift 6 app build — all green
- **More real packages — ora, yargs, enquirer — surfaced 7 engine bugs.**
  The real-package method again: install popular CLIs and run them, fix
  what breaks. ora (spinner) renders; yargs (arg parser) parses correctly;
  enquirer loads. Seven genuine gaps that would break real tools: (1)
  `stdin.isPaused` and (2) `stdin.prependListener` missing from the stdin
  shim; (3) a transpiler **`require` TDZ** — a module doing `const require
  = createRequire(...)` (legal ESM, the dual-package idiom) shadows the
  wrapper's `require` PARAMETER scope-wide, putting the transpiled imports
  above it in TDZ; fixed by routing generated import-requires through a
  separate `__mouseRequire` parameter the shadow can't reach; (4) the
  ES2022 **`export {x as 'module.exports'}`** string-named-export idiom
  (yargs/cliui) → now emits `module.exports = x`; (5) the `export default`/
  `export const` rules lacked the mid-line `(?:^|(?<=[;}]))` anchor, so an
  unterminated import (cliui, no semicolons) whose trailing newline got
  consumed left `;export default` mid-line and unmatched; (6) TTY
  WriteStream cursor helpers `cursorTo`/`moveCursor`/`clearLine`/
  `clearScreenDown` missing from stdout/stderr (ora/cli-progress use them);
  (7) `assert.notStrictEqual` + `notDeepStrictEqual`/`doesNotThrow`/`match`/
  `ifError`/`fail` missing. Regression fixtures `assert-more` and
  `yargs-cli` (the latter exercises the createRequire-shadow AND the
  string-export idiom end to end) — both byte-identical to real node v22.
  39 node fixtures, screen corpus, pyte cross-check, 56 TTY assertions,
  e2e, sh corpus, Swift 6 build — all green
- **Batch 2: date-fns, fs-extra, glob, picocolors, nanoid — 3 more gaps.**
  picocolors and date-fns passed outright. nanoid needed the WEB crypto
  global (`crypto.getRandomValues`/`randomUUID` — distinct from the
  `crypto` module; browser-targeted libraries reach for it). fs-extra
  needed `fs.realpath` (callback form) and its `.native` variant
  (graceful-fs patches them). glob was the dangerous one: **silently
  empty** — status 0, wrong answer — because `readdirSync(dir,
  {withFileTypes: true})` ignored the option and returned strings;
  path-scurry read `isDirectory()` off a string as undefined and matched
  nothing. Now returns Dirent-shaped objects (name/parentPath +
  isFile/isDirectory/… methods). glob finds files correctly. Regression
  fixtures `readdir-dirent` and `realpath-webcrypto`, both byte-identical
  to real node v22 — 41 node fixtures total; full battery green
- **Batch 3: inquirer, axios, semver, js-yaml — 7 more fixes, incl. a
  phase-F bug and a module-system semantics bug.** js-yaml and axios
  passed. semver wouldn't even INSTALL: the PackageManager range parser
  choked on `>= 2.1.2 < 3.0.0` (space between operator and version —
  safer-buffer's published range); fixed by rejoining bare-operator
  tokens, with 4 new semver-corpus cases. Then semver-the-package exposed
  **circular-require semantics**: it assigns `module.exports = Class`
  BEFORE requiring its cyclic partner, and real node's cycle-hit reads
  `module.exports` LIVE — ours returned a stale pre-evaluation snapshot,
  so `instanceof Comparator` saw an empty object. Fixed with a
  modules-in-progress map that reads exports off the live module object
  (fixture `circular-live-exports`). inquirer (the ecosystem's biggest
  prompt library) took five: `util.styleText` (with node's TTY/NO_COLOR/
  FORCE_COLOR gating — the fixture caught ours coloring unconditionally);
  legacy `Stream.prototype.pipe` (mute-stream calls `super.pipe`);
  readline `getCursorPos`/`line`/`cursor`; AsyncLocalStorage keeping its
  store across awaits (promise-aware `run` — correct for non-interleaved
  flows, the honest single-thread limit); and terminal readline
  interfaces AUTO-WIRING keypress decoding (real node does it inside
  `createInterface({terminal:true})`; inquirer never calls
  emitKeypressEvents itself). inquirer now prompts, echoes, and answers
  end-to-end (`ANSWER=bob`). Also fixed the pkg harness's pnpm
  comparison: pnpm 11's default `minimumReleaseAge` supply-chain gate
  skips versions <24h old and lost us a publish race
  (brace-expansion@1.1.17 landed mid-session); the harness now passes
  `--config.minimum-release-age=0` to compare pure resolution. (That gate
  is worth considering for OUR installer someday — noted, not built.)
  43 node fixtures + PHASE F ALL PASS + full battery green
- **Batch 4: REAL TSC COMPILES TYPESCRIPT ON THE ENGINE — a phase-D
  milestone proven early.** typescript@5.9.3's `transpileModule` emits
  correct CommonJS from TS source, byte-identical to real node (fixture
  `tsc-cli`). lodash and zod passed outright. Two findings en route:
  (1) typescript@7 is the GO-native tsc — like claude-code 2.x, another
  the-future-is-native data point; 5.x is the JS-runnable compiler, so
  phase D targets `typescript@^5`. (2) prettier exposed two transpiler
  bugs: dynamic `import()` is legal in CJS too (prettier lazy-loads
  parsers with it) and JSC's native import has no loader — now rewritten
  through `__dynamicImport` in CJS as well (fixture `dynamic-import-cjs`);
  and ESM files legitimately declare `const __filename =
  fileURLToPath(import.meta.url)`, which our substitution turned into a
  TDZ self-reference — `import.meta.url` now routes through a
  shadow-proof `__mouseFilename` wrapper param (fixture
  `filename-shadow-esm`). prettier now formats correctly (clean output;
  its exit code shows the dangling-promise 13 quirk — output intact,
  recorded as a follow-up lead). 46 node fixtures, full battery green
- **The exit-13 quirk was a RACE in entry settlement — fixed.** Even
  `await Promise.resolve(1)` as an entry exited 13 with correct output.
  Mechanism: JSC drains microtasks when the launcher call's VM entry
  exits, so a pure-microtask entry settles DURING the call — the settled
  callback clears `entryPending` — and the Swift line after the call
  assigned `finished != true`, overwriting the clear and stamping 13 on a
  healthy run. Timer-based entries (the esm-tla fixture) settle later and
  never hit it, which is why the suite missed it; prettier's
  microtask-final await chain exposed it. Fix: set the flag BEFORE the
  call, only ever CLEAR it after. prettier now exits 0. Fixture
  `microtask-only-tla` pins the pure-microtask entry path against real
  node — 47 node fixtures, full battery green
- **A real claude-code ink frame renders ALIGNED on the phase-T screen —
  ONLCR.** Captured 1748 bytes of claude-code 1.0.128's config-recovery
  UI (a bordered "Configuration Error / Choose an option" dialog) from the
  live engine, fed it into `TerminalScreen`: the box SHEARED diagonally.
  Cross-checked against pyte — pyte sheared identically, so the emulator
  is correct (bare LF is index, xterm-faithful). The real cause: ink's
  inline frames end each line with a bare `\n` and rely on the TTY's ONLCR
  (map NL→CR-NL on output) — an output-termios flag that stays on even
  when stdin is raw. Our PTY substitute wasn't applying it. Added
  `NodeProgram.onlcr` at the program→screen boundary (bare `\n` → `\r\n`,
  a split `\r\n` becoming a harmless `\r\r\n`), keeping `TerminalScreen`
  pure so the pyte cross-check still holds. The exact captured frame now
  renders byte-for-byte against pyte's ONLCR render — a clean bordered
  dialog — and a control assertion proves it shears without the fix. This
  is the loop's headline ask ("Node programs drive the phase-T screen for
  ink-style TUIs") verified with real published-CLI output. 51 TTY
  assertions, 35 node fixtures, e2e, sh corpus, Swift 6 build — green
- **Ink REPAINT path cross-checked against pyte — no bug, confirmed
  correct.** Static frames alone don't exercise how a live TUI updates:
  cursor-up over the prior frame, erase-line, erase-below, overwrite. Ran
  two real ink apps through the engine capturing their raw multi-frame
  output — one changing content WIDTH per frame (wide→narrow→wide, stresses
  leftover-tail erase), one changing HEIGHT (a 4-line box collapsing to a
  single line, stresses erase-display-below) — and rendered each full
  stream through `TerminalScreen` (with ONLCR) and through pyte. Both
  final grids are byte-identical to pyte: clean borders, no stale rows or
  tails from taller/wider prior frames. The repaint path is correct as-is;
  this iteration adds verification, not code. The ink-TUI goal is now
  verified end-to-end headlessly (load → first frame → width/height
  repaints), all against the pyte reference; what remains is live-driving
  on device and phase B
- **Terminal query→response protocol — the reply half of the TTY.** A TUI
  doesn't just write; it ASKS: DSR (`ESC[6n`, "where's the cursor?"), DA
  (`ESC[c`, "what are you?"), DECRQM (`ESC[?2026$p`, "is synchronized
  output on?") — and BLOCKS reading stdin for the answer. Our parser
  consumed these silently and answered nothing, so a program gating on a
  reply would hang (claude-code's bundle emits DSR). Added
  `AnsiParser.respond`, wired by `TerminalSession.launch` to the program's
  `input` (cleared on exit): `ESC[6n` → `ESC[<row>;<col>R`, `ESC[5n` →
  `ESC[0n`, primary DA → `ESC[?6c` (VT102), secondary DA → `ESC[>0;10;0c`,
  DECRQM → `ESC[?<n>;<state>$y` (2=recognized-but-reset for 2026/2004;
  live state for cursor-visibility and alt-screen). Verified end-to-end:
  a program parks its cursor, emits all three queries, and receives
  exactly `ESC[1;6R` + `ESC[?6c` + `ESC[?2026;2$y` on stdin, then exits —
  no hang. `respond` is nil for the pyte cross-check and static renders,
  so queries stay screen-invisible there and BOTH the ~60-assertion xterm
  corpus and the pyte cross-check still pass. 55 TTY assertions, 35 node
  fixtures, e2e, sh corpus, Swift 6 build — green
- **Keyboard input encoding — the stdin leg.** The prompt field handled
  typed characters and Return, but nothing else: a soft-keyboard backspace
  (empty replacement over a range) fell through to the field and never
  reached the program, and hardware special keys (arrows, Home/End, Page,
  F-keys, Ctrl-combos) arrive via `pressesBegan`, which was unhandled —
  so a TUI couldn't navigate or edit. Added `TerminalKey` (pure,
  Foundation, in `TerminalPrograms.swift`): `.encoded(modifiers)` maps each
  key to its xterm bytes — cursor keys `ESC[A`…`ESC[D` (and `ESC[1;<n>X`
  with the modifier parameter n = 1 + shift + 2·alt + 4·ctrl), Home/End
  `ESC[H`/`ESC[F`, tilde-keys `ESC[2~`/`3~`/`5~`/`6~`, F1–F4 as SS3
  (`ESCOP`…), F5–F12 as CSI-tilde, Backspace→DEL, BackTab `ESC[Z`,
  Escape, Enter→CR — and `.control(for:)` for Ctrl+letter (0x01–0x1a,
  `Ctrl-[`→ESC, Ctrl-Space→NUL). The UIKit glue is thin:
  `ProgramKeyTextField.pressesBegan` maps `UIKey`/`UIKeyboardHIDUsage` →
  `TerminalKey` and routes through `onKey`; the delegate turns backspace
  into DEL. Only keys a running program consumes are intercepted; ordinary
  typing and Return are untouched. Verified in the screen harness (~35
  assertions): every encoding checked against the xterm spec, plus a round
  trip proving `encoded()` arrows move the parser's cursor exactly as the
  escape says. Screen corpus, pyte cross-check, 55 TTY assertions, node
  fixtures, e2e, and the Swift 6 app build all stay green
- **DECCKM — application cursor keys.** The encoding above always emitted
  CSI arrows (`ESC[A`), but a program that sets DECCKM (`ESC[?1h` — vim,
  readline) expects and binds the SS3 form (`ESC O A`). Our `setMode`
  ignored mode 1 and `TerminalKey` had no notion of it, so a strict TUI's
  arrows would miss. `TerminalScreen` now tracks `applicationCursorKeys`
  (set/reset by mode 1); `TerminalKey.encoded(_, applicationCursor:)`
  emits SS3 for the unmodified arrows/Home/End when it's on and CSI
  otherwise (modified keys always CSI, per xterm); and the encoding moved
  from the field to `TerminalSession.sendSpecialKey`, which reads the
  screen's live mode — the only place that knows it. The parser also
  learned to READ SS3 (`ESC O A/B/C/D/H/F` move the cursor like their CSI
  twins), so application-mode output positions identically. Verified:
  DECCKM flips the encoding both ways, modified arrows stay CSI, SS3 and
  CSI arrows move the cursor identically, and mode 1 round-trips through
  the parser; the pyte cross-check still matches (SS3 included), and the
  screen corpus, TTY, node fixtures, e2e, and app build stay green
- **Bracketed paste — honored, not just accepted.** Mode 2004 was
  advertised as understood but never acted on: the DECRQM reply even
  hard-coded "reset", a lie once a program set it. So a multi-line paste
  into a TUI arrived as raw newlines and a naive prompt fired line-by-line
  — the wrong thing for the agent-CLI case of pasting a code snippet or
  error log. Now `TerminalScreen` tracks `bracketedPaste` (set/reset by
  2004, reported truthfully by DECRQM), and `TerminalSession.sendPaste`
  wraps the text in `ESC[200~`…`ESC[201~` when it's on (raw otherwise),
  encoded where the mode lives; `ProgramKeyTextField.paste` overrides the
  field's paste to forward the pasteboard text as one delivery. Verified
  end-to-end: a program enables 2004, receives a 3-line paste as a single
  bracketed block (markers present, inner text intact), and a control on
  the screen state confirms 2004 flips both ways. 56 TTY assertions,
  screen corpus, pyte cross-check, 35 node fixtures, e2e, Swift 6 app
  build — green. With this the stdin leg is complete: characters, special
  keys (incl. DECCKM), Ctrl-combos, backspace, and now paste all reach a
  program the way a real terminal delivers them
- **Resize+repaint cross-checked against pyte — the rotate-mid-TUI path.**
  The one output path left unverified with real content: a device rotation
  resizes the grid (`TerminalScreen.resize`) while a program is live, and
  the program re-renders at the new width. Ran a real ink app that renders
  a bordered box sized to `process.stdout.columns`, resized the TTY 60→40
  mid-run (firing ink's `resize` event → re-render), captured the byte
  stream split at the resize point, and replayed it through both
  `TerminalScreen` and pyte with the same `resize(12,40)` at the split.
  Both final grids are byte-identical: the box re-renders cleanly at width
  40 ("width is 40"), no stale 60-wide content surviving the shrink.
  `TerminalScreen.resize` (top-left preserve, margins reset) is correct
  with a real program's resize re-render; verification pass, no code
  change. The phase-T output path is now verified end-to-end against pyte
  at every stage: first frame (ONLCR), width/height repaints, query
  replies, and resize.
  **Live in-app verification (running the app in the iOS Simulator) is
  blocked** on the host's Xcode selection — the simulator integration
  needs `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`,
  which requires the user's password. `xcodebuild` works (builds pass);
  only the Simulator attach is gated. Everything provable headlessly is
  proven; the remaining feel-test waits on that one host fix or moves to
  phase B.
- **The T↔G join (raw TTY/stdin)** — headless per the AGENTS.md
  TerminalPrograms rule (`TerminalProgramIO.write` → `AnsiParser`, grid
  asserted after keystrokes): 26 assertions across transcript streaming
  (isTTY/size real, stderr colored, escapes stripped, partial lines
  flushed), stdin liveness (a waiting listener holds the loop open; exit
  frees it), raw-mode grid painting with keystroke redraws, ^C discipline
  both ways (cooked kills at 130 or runs the SIGINT handler; raw delivers
  the byte), resize events, and alt-screen enter/restore. Plus 9
  end-to-end through msh itself: `node tui.js` typed at the prompt hands
  the terminal a `NodeProgram` titled like the command, raw paint lands on
  the grid at the true geometry, and a mid-pipeline `node` stays headless
  (data, not a program). En route this pass found a real Swift bug — CRLF
  is ONE Character to Swift, so line-splitting/escape-stripping had to
  drop to unicode scalars (same grapheme trap the pyte pass caught in the
  parser). The 25-script sh corpus and all 19 node fixtures stayed green;
  the app builds under Swift 6 strict concurrency

Method to reproduce: `Shell.swift`, `GitCore.swift`, and `GitRemote.swift`
are Foundation-only by design. Compile them with a scratch `main.swift` via
`swiftc` (add `-lz` for GitCore) and assert. Scratchpad harnesses are not
preserved between sessions — rebuild from this description.

### Open decisions (need a human)

1. **App Review framing** for signing ([xcode.md](xcode.md) §7) — main app,
   developer-mode flag, or separately distributed build? Decide before that
   plan's Phase 3.
2. **Android parity** for the git toolbar — the Kotlin Graph container is
   still display-only.
3. Whether `system` becomes a real branch now or stays a plan.

---

## 1. Platform physics

Non-negotiable, and the source of every design decision below.

### The three rules

1. **Signing.** Before the CPU may execute any memory as instructions,
   those exact bytes must carry a signature Apple issued at install time.
   Downloaded machine code can never satisfy this. `chmod +x` sets the bit
   (Mouse's `chmod` really does); the kernel still refuses.
2. **No `fork`/`exec`.** An app cannot spawn a program — not even a signed
   one. Everything happens inside the single app process. This is why `msh`
   is a shell *implemented inside* Mouse, not a shell that launches `ls`.
3. **No JIT** — writing fresh machine code at runtime and jumping into it.
   With exactly one exception, below.

### What the rules permit

**Interpretation.** The ban is on the CPU *jumping into* untrusted bytes.
It is not a ban on Mouse's signed code *reading* those bytes and acting on
them. To the kernel, interpreting a program is indistinguishable from
reading a text file — because that is what it is.

This single loophole is load-bearing for the entire `system` branch.

### The one legal JIT

**WebKit's.** The web content process carries a code-signing entitlement
third-party apps cannot obtain, and Apple grants it to the browser engine
any app may embed. Consequences:

- `JSContext` **in our process has no JIT** — WebKit's low-level
  interpreter only. This is the `js` engine in
  [Terminal.swift](swift/Mouse/Terminal.swift) today: correct, and roughly
  10–30× slower than necessary.
- The **same JavaScript inside a `WKWebView` is fully JIT-compiled**, as is
  any WebAssembly it loads.

So the fastest execution surface available to Mouse is not native Swift —
it is the WebView, for anything expressible as JS or wasm.

### The rule that is policy, not physics

App Review **2.5.2** forbids downloading and executing code that changes an
app's features, with an explicit carve-out for apps that teach, develop, or
test code, provided that code is user-visible and user-editable. Mouse is
squarely in that category. Shipped proof: **a-Shell** (clang-to-wasm,
compiles C on device), **Pythonista/Pyto** (CPython built in), **iSH** (x86
emulation, `apk add` works). **Swift Playgrounds** compiles Swift on device
but on a private entitlement — proof of silicon, not of policy.

---

## 2. The four execution substrates

Choosing correctly per workload *is* the architecture.

| Substrate | Speed | Runs | Constraint |
|---|---|---|---|
| **Native (in-app)** | 1× | Swift; any C/C++ compiled in at build time | Roster fixed at ship time; app-size cost |
| **WKWebView** | ~1–3× | JS + wasm, **JIT-compiled** | Web APIs only; needs a live view; no direct filesystem |
| **In-app wasm runtime** | ~5–30× | Any `.wasm` | Interpreted; we write it |
| **In-app JavaScriptCore** | ~10–30× | JS | Interpreter only (see §1) |

### The interpreter ladder

Between "slow interpreter" and "forbidden JIT" there are rungs:

1. **Naive** — decode and dispatch every instruction, every time. ~100×.
2. **Pre-translation** — rewrite the program once at load into an optimized
   internal form; execute that. Still data, so still legal. ~10–30×.
   *WasmKit does this.*
3. **Gadget threading** — ship thousands of tiny machine-code fragments
   **signed inside the app**, one per operation. At runtime generate a
   *data table* sequencing them; each fragment tail-jumps to the next.
   Every executed instruction was signed by Apple; the downloaded program is
   reduced to a playlist. ~5–15×. *This is what iSH ships.*
4. **Real JIT** — banned, permanently.

Rung 3 is the house-style upgrade: compiling into *data* rather than code.

---

## 3. Mouse as kernel

An operating system is five jobs: a CPU, a program format, a kernel to ask
for things, processes, and a filesystem with a `$PATH`. With a wasm runtime
inside, Mouse has all five:

| Job | Mouse's answer |
|---|---|
| CPU | The wasm interpreter |
| Format | `.wasm` — a real standardized binary format with real compilers targeting it |
| Kernel | **Mouse itself.** Wasm programs cannot touch anything directly; they call named imports, and whoever supplies those imports decides what happens |
| Processes | Running wasm instances — which makes `ps`, `kill`, `&`, and pipes *true* instead of honest apologies |
| Filesystem + `$PATH` | The sandbox in an FHS-ish layout, resolved by executable bit |

### Why this is better than it sounds

1. **We are a stricter kernel than Linux.** A Linux binary can read anything
   the user can. A wasm program gets *only* the capabilities Mouse hands it
   — this workspace, nothing else. Installing a random package is safer here
   than on Ubuntu. Security as a feature, not a compromise.
2. **One ecosystem, both platforms.** The same `.wasm` runs on the iOS and
   Android apps.
3. **We own the syscall table.** WASI is thin on sockets — but since Mouse
   *is* the kernel, we can add imports: sockets over URLSession, "open in
   Viewer", "serve to the Preview container."

### The scope is finite

Mouse never maps *programs* — it implements the **alphabet**:

- **~200 wasm instructions**, most one line ("pop two, add, push")
- **~40 WASI syscalls** wired to the sandbox
- **one loader** for the `.wasm` format

Compilers do the hard part, permanently, elsewhere: `cargo build --target
wasm32-wasi` grinds a million lines into that alphabet before the package
ever reaches us. Infinity lives in the arrangements, not the vocabulary.

For comparison, this is *simpler* code than `GitCore`, which had to
understand packfiles, deltas, three protocols, and a merge algorithm.

---

## 4. Running agent CLIs

The most product-relevant section, and the one with a surprise in it.

The obvious targets (Claude Code, Hermes Agent, similar) are **not one
problem — they are two**, because they are written in different languages
with opposite cost profiles:

| | Runtime | Mouse's fastest surface | Tax |
|---|---|---|---|
| **Claude Code** | Node / JS | WebView JIT (§1) | ~1–3× — needs the Node API shim |
| **Hermes Agent** | **Python** (+ Node for its web UI) | **CPython built into the app** | **1× — native, no interpreter** |

So "if Claude Code runs, Hermes runs" does not follow. Python is the
*cheaper* runtime on iOS — bundled CPython is full speed, proven by
Pythonista and Pyto — but it drags a harder dependency problem behind it.

### 4a. The Node path — Mouse does not need to run Node, it needs to *be* Node

`npx n8n` does not execute a binary called n8n. It runs **JavaScript**
through Node, and Node is three things Mouse can supply:

| Node provides | Mouse's answer |
|---|---|
| V8 (a JS engine) | The WebView JIT surface, or JavaScriptCore |
| A standard library (`fs`, `path`, `http`, `net`, `crypto`, `child_process`) | Swift implementations over the workspace and URLSession |
| A module loader (CJS/ESM over `node_modules`) | The package manager's output |

Precedent exists: **nodejs-mobile** ships Node on iOS with V8 in jitless
mode, compiled into the app at build time (so it is signed). *Confidence:
moderate — verify current status and App Store track record before
committing to it.* Either way the work is the same shape.

### The bridge that is uniquely ours

Most Node CLIs shell out, and `child_process.spawn` is exactly what iOS
forbids. **But Mouse already has a shell.** Shim `spawn`/`exec` to dispatch
into `MouseShell`, and a tool calling `git status` or `grep` gets a real
answer from native builtins.

This is Mouse's structural advantage: every other Node-on-iOS attempt has
no shell to delegate to. We built one first, by accident of ordering.

### Blockers, in order of difficulty

1. **The Node API surface** — the bulk of the work. Finite, but months.
2. **ANSI/TUI support** — CLI tools draw with escape codes and cursor
   movement. `TerminalSession` today is a *list of lines* with a kind; TUI
   needs a **screen model** (grid, cursor, scroll region, SGR attributes).
   Buildable, and independently valuable.
3. **Native modules** (`.node`) — unsigned dylibs, never loadable. Strategy:
   shim the common ones in Swift (SQLite is already on iOS; crypto via
   CryptoKit).
4. **Memory** — the ceiling that decides feasibility more than any API.
   `os_proc_available_memory` is already wired into the `free` builtin;
   the runtime should consult it and fail honestly rather than be jetsammed.

### 4b. The Python path — and the discovery that changes the plan

**Hermes Agent** ([nousresearch/hermes-agent](https://github.com/nousresearch/hermes-agent))
is Python 3.11+ (Node only for web components), and it carries the single
most useful architectural fact in this document:

> **Hermes already supports remote shell backends: local, Docker, SSH,
> Singularity, Modal, and Daytona.**

The hardest iOS blocker for any agent CLI is that its shell tool needs
`fork`/`exec`, which does not exist here. Hermes has *already solved that
for its own reasons* — its tool execution can run on a remote sandbox over
the network while the agent loop runs locally. On iOS that is not a
workaround, it is the intended configuration:

- **Agent loop** → bundled CPython, **native speed**, on device
- **Tool execution** → Modal/Daytona/SSH sandbox, over HTTPS via URLSession
- **Local-only tools** (file edit, search, git) → Mouse's own native organs

That inverts the earlier ranking. Hermes is *heavier* than Claude Code but
**more portable**, because it does not assume local exec.

### 4c. Hermes's native dependencies map onto things Mouse already has

Its installer bundles Python 3.11, Node.js, ripgrep, ffmpeg, and MinGit —
none of which can execute on iOS. But three of the four have native
equivalents Mouse either owns or can shim:

| Hermes needs | On iOS |
|---|---|
| **ripgrep** (search) | Swap for native Swift search — the same shim Claude Code needs |
| **git** (MinGit) | **`GitCore` already exists**, from scratch and real-git-verified |
| **ffmpeg** | Shim the common paths to AVFoundation, or disable those tools honestly |
| **uv** (Rust package manager) | Not needed — Mouse resolves and unpacks packages itself (§F) |
| **Python native wheels** | The genuinely hard part: C extensions must be built into the app or exist as wasm |

Installation cannot be `curl … | bash`. It must be "resolve and unpack the
Python package into the bundled CPython," which is the package manager's
job, not a shell script's.

### 4d. What Hermes needs that Mouse does not have

- **A real TUI.** Hermes has "multiline editing, slash-command autocomplete,
  conversation history, interrupt-and-redirect, and streaming tool output."
  That is a full ANSI screen application. `TerminalSession` is a list of
  lines — this is the largest single gap, and it is shared with Claude Code.
- **Long-lived background processes.** The gateway (messaging), the cron
  scheduler, and subagent RPC all assume daemons. iOS suspends backgrounded
  apps; these are foreground-only here, or they live on the remote sandbox.
- **Subagent spawning via RPC** — fine, since it is already network-shaped.

### Per-target assessment

| Target | Runtime | Verdict |
|---|---|---|
| **Hermes Agent** | Python | **Best architectural fit.** Native-speed CPython for the loop; its *existing* remote-backend design sidesteps the exec problem entirely. Blockers: full TUI, native wheels, daemons. `hermes` interactive CLI is the target; `hermes gateway` is not |
| **Claude Code** | Node | **Plausible.** Filesystem is the workspace; shell-out maps to msh; network is URLSession. Blockers: the Node API shim, the same TUI, and bundled native ripgrep |
| **n8n** | Node | **Hardest.** The web UI half is lovely (Preview container displays it), but the dependency tree is enormous, it needs native modules, and its footprint fights jetsam. A trimmed subset at best; do not aim here first |
| **OpenClaw** ([openclaw.ai](https://openclaw.ai)) | Node (pnpm workspace) | **Plausible, same shape as Claude Code.** Installs via `npm i -g openclaw` or `curl -fsSL https://openclaw.ai/install.sh \| bash` — both must work in Mouse verbatim (see the install rule below). Shell-out → msh bridge; its chat-gateway/heartbeat daemons are foreground-only here; its browser-control tools have no iOS answer — those tools disable honestly |
| **opencode** ([opencode.ai](https://opencode.ai)) | TS server + **Go TUI binary** | **Split verdict.** `curl -fsSL https://opencode.ai/install \| bash` and the npm path ship a platform-native Go binary for the TUI — native binaries can never execute on iOS. The TS/JS half runs on the Node layer; the Go half needs their wasm build or stays out. Assess the client/server split when F+G land |

**The lesson to carry forward:** an agent CLI's portability to iOS is
decided less by its language than by **whether it assumes local `exec`**.
Ask that question first about any new target.

### The install rule (2026-07-27)

**The acceptance test for phases A+F+G is each target's own install
command, verbatim from its website** — `curl -fsSL … | bash`,
`npm i -g openclaw`, `npx @anthropic-ai/claude-code`. Nothing is
pre-packaged into the app; Mouse supplies the *ability* to install. That
decomposes exactly into the phases: `curl` exists today; `| bash` is
phase A (script execution); `npm`/`npx` are phases F+G. An install script
that probes `uname`, mkdirs, downloads, chmods, and edits `$PATH` must
find every one of those working.

### The runtime-acquisition decision (2026-07-27)

**Runtimes are INSTALLED, never bundled.** The product stance: Windows
doesn't ship with Python or Node either — you install them. Mouse does the
same, and the platform physics dictate the one legal form: a runtime
arrives as an **interpretable artifact downloaded as data**, executed by
machinery that shipped signed inside the app.

- **Python** = official CPython **wasm32-wasi builds**, fetched by the
  package manager, run on the in-app wasm runtime (phase E). `pkg install
  python` is a download, not an app update. Cost: interpreted speed
  (~5–30×; gadget threading narrows it) instead of bundled-native 1× —
  that is the price of not packaging Python, and it also keeps the
  zero-third-party-code invariant intact.
- **Node** never needs installing at all: Mouse's Node layer (phase G)
  *is* the runtime — JS is already data to JSContext/WebView, and npm
  packages are pure data. `node`, `npm`, `npx`, `pnpm` appear on `$PATH`
  as facets of the layer.
- **Bundled CPython (phase K) is demoted** to an optional native-speed
  escape hatch, taken only if wasm CPython proves too slow for real use.

This makes **E (wasm runtime) + F (package manager)** the trunk of the
whole system branch: together they are "install a language on a phone."

**Revised first milestone.** Given §4b, the cheapest path to a real agent in
the terminal is **not** the Node layer:

1. **ANSI screen model** in `TerminalSession` — required by every TUI agent,
   useful on its own, no iOS barrier — ✅ done
2. **Wasm runtime + package manager** (E + F) — `pkg install python`
   downloads CPython-wasm as data; nothing is bundled
3. **Hermes with a remote shell backend** — the agent loop on device, tool
   execution on a sandbox it already knows how to talk to

The Node layer (§4a) remains the right answer for the JavaScript ecosystem
and for Claude Code, but it is no longer the shortest road to "an agent
running in Mouse's terminal."

**Within the Node path, the first milestone is not a Node port.** A
Node-compatible module layer on the
WebView JIT surface, targeting single-file CLI tools (`prettier`, `tsc`,
small agents) before anything with a UI. `npx <simple-tool>` works long
before `npx n8n` is realistic.

---

## 5. The terminal's own gaps

`msh` **has a language now** (phase A, shipped): control flow
(`if`/`for`/`while`/`until`/`case`, functions), `$(…)` and backticks,
`$((…))` arithmetic, `${…}` operators, field splitting, positional
parameters, `test`/`[`, `read`, `set -e/-x/-o pipefail`, `local`/`shift`/
`break`/`continue`/`return`/`exit`, `eval`/`source`, and script execution
(`sh file`, `sh -c`, `./script.sh` with shebang, `curl url | sh`).
Verified against real `/bin/sh` on a 25-script corpus (method in
AGENTS.md).

Still missing, in rough priority for install scripts:

- **Heredocs** (`<<EOF`) — install scripts use them constantly
- **stderr redirects** (`2>`, `2>&1`)
- **Subshells** (`( … )`) and `$(…)` env isolation (ours mutates)
- **Job control** — `&`, `jobs`, `fg` (needs §3's processes to be real)
- **Aliases, tab completion, multi-line prompt continuation**
  (`ShellParseError.incomplete` is already reported for the prompt to use)

Cheap adjacent win: the `js` engine is REPL-only. `js script.js` with a
small `fs` shim gives a real scripting language immediately.

---

## 6. Unified phase map

Merging this document, [compile.md](compile.md), and [xcode.md](xcode.md)
into one order. Each ships something usable alone.

```
A  msh language           control flow, $(), script files      ✅ DONE — see §5
B  WebView compute engine the only legal JIT; 10–30× on JS     small, huge leverage
C  artifact server        serve/LAN; = xcode.md Phase 0        pays for itself 3×
D  web toolchain          tsc, bundling, Preview container     the credible-IDE milestone
E  wasm runtime           WASI, $PATH, real processes          the system substrate
F  package manager        pkg + pnpm on existing tar/gzip     ✅ DONE (resolve/install/bins; run needs G)
G  Node layer             API shim on JSContext                ✅ DONE (CJS+ESM, child_process→msh, fetch/https, raw TTY→phase-T screen, streams, readline, crypto, zlib; gaps: net, WebView JIT)
H  CI bridge              push → build → fetch artifact        unlocks Rust/Go/Swift
I  MouseSign              Mach-O + CMS, user's own cert        xcode.md Phase 1–3
J  clang-wasm             "Mouse compiles C"
K  native languages       bundled CPython/Lua — DEMOTED: only if wasm
                          builds prove too slow (see §4, runtimes are
                          installed as data, never bundled)
────────────────────────────────────────────────────────────
research  gadget interpreter · Zig/Go self-hosting · RISC-V emulation
```

**A–D alone** make Mouse a credible IDE for the largest developer
population there is. **E–G** make it a system. **H–I** close the native-app
loop.

### The agent track cuts across it

Per §4b, "run a real agent in the terminal" does **not** wait for the whole
map. It needs three items, two of which are already on it:

```
T  ANSI screen model      grid + cursor + SGR in TerminalSession   ✅ DONE — see §0
E+F  wasm runtime + pkg   `pkg install python` — CPython-wasm as data
   Hermes + remote backend  agent loop local, tools on a sandbox
```

`T` shipped: the screen model
([TerminalScreen.swift](swift/Mouse/TerminalScreen.swift)), the program
contract ([TerminalPrograms.swift](swift/Mouse/TerminalPrograms.swift)),
and the grid renderer + key routing in
[Terminal.swift](swift/Mouse/Terminal.swift), proven by a real pager and a
live `top`. Every future interactive surface — agent CLIs, editors, wasm
processes — enters the terminal through `TerminalProgram`.

---

## 7. Verification standards

Per [AGENTS.md](AGENTS.md), and non-negotiable: interop with real tools is
mandatory, not optional.

| Component | Verified against |
|---|---|
| wasm runtime | The **official WebAssembly spec test suite** (`spec/test/core`) — thousands of assertions |
| WASI layer | wasi-testsuite; plus adversarial sandbox escape attempts (`../`, symlinks, absolute paths) |
| Node layer | Real Node's output for the same script, on a fixture corpus |
| Package manager | Resolved tree vs real `pnpm install --lockfile-only` |
| ANSI/TUI | A known-good terminal's screen state for the same escape stream |
| Bundler | Byte-compare with real `esbuild`/`swc` |
| Signing | `codesign -vvv --deep --strict`, blob-by-blob diff against Apple's own output |

Foundation-only components verify headlessly (`swiftc` + scratch
`main.swift`). Keep new engines Foundation-only for exactly this reason.

---

## 8. Distribution reality

The engineering is the easy part.

- **The dev-tool carve-out (2.5.2) is the whole basis.** Keep user code
  visible and editable; never download code that alters Mouse itself.
- **Signing is the review risk**, not execution. General re-signing of
  arbitrary IPAs is why AltStore lives outside the App Store. Signing *the
  user's own* build with *their own* certificate is defensible — but
  untested until asked. See [xcode.md](xcode.md) §7.
- **Bring-your-own is the rule** ([xcode.md](xcode.md) §1): Mouse never
  manufactures credentials, licenses, or trust. It accepts what the user
  holds and does the work with it. Apple-licensed SDKs come from the user.
- **App size** is a real budget. clang-wasm and CPython are tens of
  megabytes each. Bundle the core; download the rest as data.
- **Idea on file (2026-07-27): Mouse Lite / Mouse Heavy.** Two app
  packages: Lite ships the core and installs runtimes on demand (the
  default stance); Heavy ships with everything pre-packaged for
  offline-first and zero-setup. Same codebase, a bundling flag. Revisit
  when E+F exist and the artifacts to pre-bundle are real.

---

## 9. The through-line

Every wall in this project has the same shape, and so does every door:

> **Mouse cannot be granted permission to write new machine code — but it
> can always read, sequence, and interpret. And one sanctioned JIT is
> sitting inside a WebView, waiting to be used.**

The one wall with no door is *trust*: a phone cannot vouch for software.
That is not a gap we are insufficiently clever to close — it is the
load-bearing wall of the platform, and the correct response is to route
around it for sixty seconds (CI) and come right back.
