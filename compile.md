# compile.md — running and compiling code on the device

The question underneath the `system` work, asked for every language at once:

> *What can Mouse compile and run on the phone itself, with no machine on
> the other end?*

**Verdict: more than expected, and the ordering is counter-intuitive.**
Web languages reach *full native speed today* through a door most people
miss. C and C++ compile on device for real. Systems languages with
LLVM-sized compilers stay on CI. Nothing here needs an entitlement Apple
withholds.

This is a plan, not shipped behavior. Two companions:
**[system.md](system.md)** is the umbrella spec (platform physics, the
runtime substrate, Mouse-as-kernel, the **Node compatibility layer** that
makes `npx` reachable, and the unified phase map);
**[xcode.md](xcode.md)** covers the one case this document defers — signing
and installing a native iOS app.

## 1. The two questions

Every language splits into two independent questions, and conflating them
is what makes this topic confusing:

1. **Can the compiler run here?** A compiler is just a program. It needs to
   be native (built into Mouse), interpreted, or wasm.
2. **Can the output run here?** Also just a program. Same three answers.

A language has a **full on-device loop** only when both are yes. When only
the second is yes, the loop routes compilation through CI and runs the
artifact here — which is still a real workflow, not a consolation prize.

## 2. The four execution substrates

Everything in this document runs on one of four surfaces. Their speeds
differ by more than an order of magnitude, so choosing correctly per
workload *is* the architecture.

| Substrate | Speed | Runs what | Constraint |
|---|---|---|---|
| **Native (in-app)** | 1× | Swift, and any C/C++ library compiled in at build time | Roster fixed at ship time; app-size cost |
| **WKWebView** | ~1–3× | JS and wasm, **JIT-compiled** | Web APIs only; needs a visible view; no direct filesystem |
| **In-app wasm runtime** | ~5–30× | Any `.wasm` | Interpreted; we write it |
| **In-app JavaScriptCore** | ~10–30× | JS | **Interpreter only — see below** |

### The JIT nuance that reorders everything

There is exactly one legal JIT on iOS: **WebKit's**. The web content
process carries a code-signing entitlement third-party apps cannot get, and
Apple grants it to the browser engine any app may embed.

The consequence is sharp, and Mouse is currently on the wrong side of it:

- `JSContext` **in our process has no JIT.** It runs WebKit's low-level
  interpreter. This is the `js` engine in [Terminal.swift](swift/Mouse/Terminal.swift)
  today — correct, persistent, and roughly 10–30× slower than it needs to be.
- The **same JavaScript in a `WKWebView` is fully JIT-compiled**, along with
  any WebAssembly it loads.

So the fastest execution surface available to Mouse is not native Swift —
it's the WebView, for anything expressible as JS or wasm. That single fact
is why Phase 1 below is a WebView compute engine rather than an interpreter.

## 3. What the rules actually permit

App Review Guideline **2.5.2** forbids downloading and executing code that
changes an app's features. It carries an explicit carve-out for apps that
teach, develop, or test code, provided the code is user-visible and
user-editable. That is precisely Mouse's category, and the carve-out is
load-bearing for an entire shelf of shipped apps:

| App | What it proves |
|---|---|
| **a-Shell** | Ships clang compiled to wasm; **compiles C on device** and runs the result |
| **Pythonista / Pyto** | CPython built into the app at native speed; `pip` for pure-Python packages |
| **iSH** | Emulates x86, runs unmodified Alpine binaries, `apk add` works |
| **Swift Playgrounds** | Full on-device Swift compile-and-run — *but* on a private entitlement, so it is proof of silicon, not of policy |

**Scope discipline**, matching [xcode.md](xcode.md)'s bring-your-own rule:
Mouse compiles the user's own source into artifacts the user controls. It
does not download code that alters Mouse itself, and every toolchain it
ships is one it can redistribute. Apple-licensed SDKs are supplied by the
user or never touched.

## 4. The language matrix

The answer to "any and all languages," honestly, one row at a time.

### Full on-device loop — compiler and output both run here

| Language | Compiler path | Output runs on | Notes |
|---|---|---|---|
| **JavaScript** | none needed | WebView (JIT) | The strongest case. Full speed today once Phase 1 lands |
| **TypeScript** | `tsc` (pure JS) or SWC/esbuild-wasm | WebView | `tsc` is JavaScript, so it runs on the same surface it compiles for |
| **HTML/CSS + frameworks** | PostCSS, Tailwind, Sass (all JS) | WebView + Preview container | The complete web-dev loop |
| **C / C++** | **clang compiled to wasm** (WASI SDK) | wasm runtime or WebView | Proven by a-Shell. Slow but genuinely compiles |
| **Python** | none (bytecode is internal) | Native — CPython built in | Full speed. Pure-Python packages via pip; C extensions need wasm builds |
| **Lua** | none | Native — ~200 KB to embed | Cheapest win in the table |
| **Ruby** | none | Native, or official `ruby.wasm` | |
| **SQL** | none | Native — SQLite is already on iOS | |
| **msh scripts** | none | Native | Needs shell control flow (`if`/`for`/`$()`), tracked separately |

### Output-only — compile on CI, run the artifact here

| Language | Why the compiler can't run here | What still works |
|---|---|---|
| **Rust** | rustc is LLVM-sized; no practical wasm build | `cargo build --target wasm32-wasi` on CI → the `.wasm` runs on device, in the runtime or the WebView |
| **Swift** | swiftc is LLVM-sized, and the iOS SDK is ~10 GB and not redistributable | CI build → **sign on device** ([xcode.md](xcode.md)) |
| **C#** | — | Blazor's runtime and Roslyn already run in wasm; a WebView-hosted C# loop is plausible and worth a spike |
| **Kotlin / Java** | Compilers are JVM programs; a JVM without JIT is painful | Kotlin/Wasm output runs here fine |
| **Go** | Compiler is self-hosted and *can* target wasm — demos exist, nothing production | TinyGo output runs here; compiler is research |

### Research — plausible, unproven, not milestones

- **Zig**: the most promising systems language to self-host here. Small
  toolchain, its own wasm backend, active work on wasm-hosted builds.
- **Go and Rust self-hosting in wasm**: both are theoretically reachable
  (Go's compiler is Go; Rust has a Cranelift backend); both are large.
- **RISC-V emulation**: the maximal door — a usermode emulator (~50 base
  instructions) running Alpine or Ubuntu's real `riscv64` packages, `apt`
  and all. This is the "inherit someone else's whole universe" option and
  belongs to the `system` branch, not here.

### Never, and correctly so

Producing a **native arm64 binary and running it on this device**. Mouse can
*emit* one (writing bytes is legal) and export it via the artifact server
for use elsewhere — but iOS will not execute unsigned machine code, and no
interpreter trick changes that. See [xcode.md](xcode.md) §1.

## 5. Phase plan

Ordered by value per unit of work. Each phase ships something usable alone.

### Phase 1 — the WebView compute engine

The highest-leverage item in this document, and among the smallest.

A `WKWebView` used purely as an execution surface: no chrome, no browsing,
a message bridge in and out, and a virtual filesystem shim backed by the
workspace. It becomes a third terminal engine beside `msh` and `js`.

- Bridge: `WKScriptMessageHandler` in, `evaluateJavaScript` out; structured
  request/response with an ID so calls can be concurrent
- FS shim: `readFile`/`writeFile`/`readdir` proxied to Swift, clamped to the
  workspace root exactly as the shell's `resolve` already clamps
- Console and errors routed to terminal scrollback, so it *feels* like `js`
- **Practical caveat:** WebKit throttles or terminates content processes for
  views not in the hierarchy. The engine must keep a real (1×1, hidden)
  view attached, and must survive process termination by re-creating and
  replaying setup.

Deliverable: `js` gains a JIT-backed sibling. Existing scripts get 10–30×
faster with no change to their source.

### Phase 2 — the web toolchain (`build`, `serve`, Preview)

With Phase 1, the JavaScript ecosystem's own tools simply *run*:

```
~ $ tsc                       # pure JS, on the JIT surface
~ $ build                     # esbuild-wasm or SWC-wasm
~ $ serve dist
serving dist on http://192.168.0.26:8080
```

- **Correct the roadmap here.** [ROADMAP.md](ROADMAP.md) says the dev-server
  engine uses "statically-linked esbuild." esbuild is a **Go binary** — it
  cannot exec on iOS and exposes no C API. The real options are
  **esbuild-wasm**, **SWC-wasm**, or skipping bundling entirely and serving
  native ESM with on-the-fly transforms (the Vite model), which suits a
  phone better anyway.
- `serve` is [xcode.md](xcode.md)'s Phase 0 artifact server, unchanged. One
  server serves the Preview container, artifact export, and OTA install.
- Because we control the server's headers, we can send COOP/COEP and unlock
  **wasm threads** in the WebView — the door to parallel compilation later.

Deliverable: a real web development loop, entirely on device, at full speed.
This is the milestone that makes Mouse a credible IDE for the largest
developer population there is.

### Phase 3 — the in-app wasm runtime

The WebView is fast but web-shaped: no real filesystem, no sockets, no
terminal I/O. CLI tools need a runtime inside Mouse.

- Start with **WasmKit** (pure Swift, interpreter — legal, no JIT) to get
  the system standing up
- Implement **WASI preview 1** (~40 calls) against the workspace sandbox
- This is where `$PATH`, executable bits, and **real processes** arrive:
  `ps`, `kill`, `&`, and pipes between running programs stop being honest
  apologies and become true
- House-style upgrade, later: a from-scratch **gadget-threaded interpreter**
  — thousands of signed machine-code fragments sequenced by a data table,
  the technique iSH ships. Compiling into *data*, never into code

Deliverable: downloaded `.wasm` programs run as first-class processes.

### Phase 4 — the package manager

Reuses machinery Mouse already owns: HTTP, native tar/gzip, and a
content-addressed store.

- `pkg install <tool>` — wasm binaries into an FHS-ish layout (`/usr/bin`),
  resolved by `$PATH`
- `pnpm install` — the npm registry, lockfile-driven. Most npm packages are
  *source*, so they need no compilation at all
- Integrity: verify checksums; record what was installed and from where

### Phase 5 — clang: compiling C and C++ on device

The proof that Mouse compiles, not just runs.

- Ship **clang built for `wasm32-wasi`** plus a WASI sysroot
- `cc hello.c -o hello.wasm` → runs on the Phase 3 runtime
- Honest cost: the toolchain is tens of megabytes of app size, and
  compilation is interpreted, so it is *slow* — fine for a file, painful for
  a large project

### Phase 6 — bundled native languages

Full speed, no interpreter, chosen at ship time:

- **CPython** compiled into the app (the Pythonista model) — `python` at
  native speed, plus `pip` for pure-Python wheels
- **Lua** and **QuickJS** — small, embeddable, useful as scripting glue
- Each addition is an app-size decision and an App Review surface; add
  deliberately, not opportunistically

### Phase 7 — the CI bridge

For everything in the output-only tier. Mouse already owns the git half.

```
~ $ git push          # Actions builds Rust/Go/Swift
~ $ ci watch          # run status streamed into the terminal
~ $ ci fetch          # artifact lands in the workspace
```

Then Phase 3 runs the `.wasm`, or [xcode.md](xcode.md) Phase 3 signs the
`.ipa`. This is what makes "any and all languages" true in practice rather
than only in theory.

## 6. Cross-cutting concerns

These apply to every phase and are cheaper to design in than to retrofit.

- **Build cache.** Content-address every artifact by hash of (source +
  toolchain + flags), the `ccache` model. On a device this slow, the fastest
  compile is the one that doesn't happen.
- **Memory discipline.** iOS jetsams hungry apps, and LLVM is hungry. The
  `free` builtin already reads `os_proc_available_memory` — the compiler
  driver should check it before starting a translation unit and fail with an
  honest line rather than dying silently.
- **Cancellation.** Compilation is the first genuinely long-running work in
  Mouse. It must honor the existing any-keypress interrupt, which means the
  runtime needs a cooperative "stop" check in its dispatch loop.
- **Where artifacts live.** `.wasm` output belongs in the workspace next to
  the source (visible, git-able, per the carve-out's "user-editable" spirit),
  while toolchains belong outside it, so `git status` never fills with
  megabytes of compiler.

## 7. Verification plan

Per [AGENTS.md](AGENTS.md): Foundation-only components verify headlessly via
`swiftc` and a scratch `main.swift`, and interop with the real tools is
mandatory — the same standard `GitCore` was held to.

| Component | Verified against |
|---|---|
| wasm runtime | The **official WebAssembly spec test suite** (`spec/test/core`) — thousands of assertions, the gold standard |
| WASI layer | wasi-testsuite; plus a from-scratch check that path preopens cannot escape the workspace |
| TypeScript builds | Output byte-compared with real `tsc` on the same input |
| Bundler | Output compared with real `esbuild`/`swc` for a fixture project |
| clang on device | Compile a fixture to `.wasm`; run it; compare stdout with the same program compiled by host clang |
| Package manager | Resolved tree compared with real `pnpm install --lockfile-only` |
| Build cache | Same inputs → cache hit; one changed byte → miss (no false hits, ever) |
| Sandbox | Adversarial: `../` traversal, symlinks, absolute paths all refused |

## 8. Frictions to state up front

- **Speed is the permanent tax.** Interpreted compilation is 5–30× slower
  than native. A file is fine; a large project is not. The WebView path
  escapes this — which is exactly why web languages lead the plan.
- **App size.** clang-wasm and CPython are tens of megabytes each. Bundle
  the core, download the rest as data.
- **WebView lifecycle.** Content processes get terminated under memory
  pressure and in the background. The engine must treat restart as normal.
- **Long builds vs. the app lifecycle.** iOS suspends backgrounded apps.
  Compilation is foreground work, or it is a CI job.
- **The npm long tail.** Packages with native addons won't build here; the
  answers are wasm builds or pure-JS equivalents, not wishful thinking.

## 9. Recommended order

```
Phase 1  WebView compute engine     ← highest leverage, smallest lift
Phase 2  web toolchain + serve      ← the credible-IDE milestone
Phase 3  in-app wasm runtime        ← processes, $PATH, real ps/kill
Phase 4  package manager            ← pkg + pnpm, on existing tar/gzip
Phase 7  CI bridge                  ← unlocks Rust/Go/Swift immediately
Phase 5  clang on device            ← "Mouse compiles C"
Phase 6  bundled native languages   ← python at full speed
────────────────────────────────
research  gadget interpreter, Zig/Go self-hosting, RISC-V emulation
```

Phases 1, 2, and 7 together already answer *"can I build and run my project
on my phone?"* for most working developers — and Phase 1 alone makes the
JavaScript Mouse runs today an order of magnitude faster.

The through-line, same as every wall in this project: **Mouse cannot be
granted permission to write new machine code, but it can always read,
sequence, and interpret — and one sanctioned JIT is sitting inside a
WebView, waiting to be used.**
