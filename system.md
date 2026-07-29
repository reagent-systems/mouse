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
matching real node). **Next:** API breadth for real agent CLIs, then
phase B (WebView JIT) for speed. Unhandled-rejection exit codes are
parked, with the reason recorded below.

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
