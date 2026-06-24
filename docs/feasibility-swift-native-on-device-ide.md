# Feasibility Study: Swift-Native Fully On-Device Agentic IDE (iOS-First)

> Status: research / scoping document. No production code is proposed here.
> Scope: assesses the architecture described in the proposal against the realities
> of iOS, the App Store, and the existing **Mouse** codebase.

## TL;DR

The proposed architecture is **mostly feasible, but only after correcting several
assumptions that do not hold on iOS**. A fully on-device, Swift-native agentic IDE
can be built and shipped to the App Store — apps in this exact category already
exist (Pythonista, Pyto, a-Shell, Swift Playgrounds, Working Copy). However, three
proposal claims are factually wrong for App Store iOS apps and drive most of the
risk:

1. **JavaScriptCore does *not* get JIT** in a third-party app. It runs
   interpreter-only. The "full JIT" claim is false on iOS.
2. **Arbitrary package installation at runtime is not feasible.** `pip install` of
   compiled wheels, `npm install` of native modules, and downloading any binary
   `.so`/`.dylib` to `dlopen` are blocked by code-signing + Guideline 2.5.2.
3. **SourceKit-LSP is not available on-device.** There is no Swift toolchain on
   iOS; "language services" must come from bundled parsers (e.g. tree-sitter),
   not LSP servers.

The single largest external constraint is **App Store Review Guideline 2.5.2**
combined with **the absence of JIT for third-party processes**. Both are
navigable — the "user writes and reads their own code in plain view" carve-out is
exactly what an IDE is — but they bound what "run code" and "install packages" can
mean.

Per-layer verdict:

| Layer | Feasibility | Main caveat |
| --- | --- | --- |
| Sandbox & VFS | High | Bookmarks only needed for *external* (Files app) URLs, not the app container |
| JS/TS runtime (JavaScriptCore) | High | Interpreter-only (no JIT); Node shim is large; no npm-native modules |
| Python runtime | Medium | Works via PEP 730 builds; **no subprocess/fork, no runtime wheel installs** |
| WASM runtime | Medium | Interpreter-only (WasmKit); slow; good for sandboxing, not speed |
| Terminal dispatcher | Medium | Not a real Unix shell; must reimplement a curated command set |
| Editor backend | Medium-High | tree-sitter yes; SourceKit-LSP no |
| Git (libgit2) | High | Mature; HTTPS clone/push/pull fine; SSH via libssh2 |
| Agent orchestrator + cloud models | High | Standard URLSession + Keychain; well-trodden |
| Local LLM (llama.cpp + Metal) | Medium | Memory limits dominate; 1B–4B Q4 only; needs entitlements + mmap |
| Persistence (SwiftData/Keychain) | High | Standard |
| Native integration (Metal/FFI/iPad) | High | Standard, with memory budget as the recurring risk |

## How this relates to the current repo

The existing app, **Mouse**, is the *opposite* architecture: a thin client to
**GitHub Codespaces**. Today, file I/O, the terminal, git, and the agent
(`opencode`) all run **remotely** inside a Codespace and are streamed to the
device over a WebSocket relay:

- Terminal is `xterm.js` over `RelaySocket` (and a mocked fallback view) — see
  `src/terminal/RelaySocket.ts` and `src/modules/views/Terminal.ts`.
- The agent shells out to `opencode` *in the Codespace* and parses its stdout —
  see `src/agents/Agent.ts` (`this.relay.startSession(...)`).
- The native shell is Capacitor (a WKWebView) for iOS/Android plus Electron for
  desktop — see `capacitor.config.ts` and `package.json`.

The proposal is therefore **not an incremental change to Mouse; it is a new,
ground-up native product.** Almost none of the current TypeScript/Capacitor code
carries over (the relay, Codespaces API, device-flow auth, and xterm view all
assume remote execution). The realistic relationship is:

- **Keep** the remote-execution model (Mouse-as-is) for heavy workloads that iOS
  cannot host (native package installs, multi-GB builds, GPUs, long-running
  servers).
- **Add or fork** a native on-device mode for offline editing, light execution,
  git, and agentic edits — accepting the constraints below.

A pragmatic product is a **hybrid of the two**: on-device for the 80% of editing /
small-script / git / agent-edit work, with an optional remote runtime (Codespaces
or similar) for the cases iOS genuinely can't do.

## The two constraints that shape everything

### 1. App Store Guideline 2.5.2 (no downloaded code that changes the app)

Apps must be self-contained; they may not download or execute code that
introduces or changes app features. There is a **narrow, well-established
carve-out** for apps where users write/read their *own* code in plain view — this
is precisely how Pythonista, Pyto, a-Shell, and Swift Playgrounds exist.

Practical rules this imposes:

- All **interpreters must be bundled** in the app binary (JavaScriptCore is part
  of iOS; Python/WASM ship inside the `.app`). ✅ Compatible with the proposal.
- **User-authored or user-fetched source code is fine to run**, as long as there
  is a clear boundary between the native runtime and the user's scripts, and the
  user can see/edit them. ✅ An IDE is the canonical example.
- **Downloading code that becomes part of *the app's own* behavior is not fine.**
  This is the line `installPackage()` repeatedly crosses if it tries to fetch and
  load compiled extensions.
- **An in-app "store/storefront" for code is not fine** (relevant if a marketplace
  of agent tools or extensions is ever added).

### 2. No JIT for third-party app processes

`MAP_JIT` / the `allow-jit` entitlement is **not available to App Store iOS apps**
(it exists on macOS hardened runtime, and via BrowserEngineKit only for EU
alternative browser engines). Consequences:

- **JavaScriptCore (`JSContext`) runs interpreter-only.** The proposal's
  "JavaScriptCore (full JIT)" is incorrect for iOS. Functionally fine, materially
  slower than desktop V8/JSC-with-JIT.
- **WASM runtimes must be pure interpreters** (e.g. WasmKit). No
  Cranelift/Wasmtime-style JIT. Expect order-of-magnitude slowdowns vs native.
- The *only* place JIT'd JS runs on iOS is inside a `WKWebView`'s separate,
  Apple-brokered WebContent process — not usable as a general embedded runtime.
- llama.cpp Metal inference is **GPU compute, not JIT**, so it is unaffected by
  this rule. ✅

## Layer-by-layer assessment

### 1. Sandbox & Virtual Environment Layer — feasible

- Projects under `Documents/Projects/<uuid>/` work directly via `FileManager`;
  the app's own container needs **no** security-scoped bookmarks. Bookmarks are
  only required for files/folders the user grants from **outside** the container
  (Files app / other File Providers via `UIDocumentPicker`). The proposal slightly
  overstates the role of bookmarks for the primary workspace.
- The thin `FileManager`/`URL` VFS wrapper (`readFile`, `writeFile`,
  `listDirectory`, `watchChanges`) is standard and a good design.
- File watching via `DispatchSource` (vnode) or `NSFileCoordinator`/
  `NSFilePresenter` works. Caveat: descriptor-based watching does not survive
  app suspension and has practical fd limits on large trees; debounce + rescan on
  foreground is the usual pattern.
- True OS-level *per-project* isolation between projects in the same app is not a
  thing; isolation is at the **app sandbox** boundary. "The agent cannot escape
  the project" must be enforced in your VFS path-normalization layer, not by the
  OS. This is fine, but it is application-enforced, not kernel-enforced.

### 2. Execution Runtime Layer

**JavaScript / TypeScript — feasible (interpreter-only).**
- JavaScriptCore is a system framework; embedding is trivial. No JIT (see above).
- A Node-API shim (`fs`, `path`, `process`, `buffer`) over the VFS is realistic
  but **non-trivial** — it's a meaningful subsystem, not a small adapter. Full
  Node compatibility (streams, net, worker_threads, native addons) is **not**
  achievable; scope it to a curated subset.
- TS/JSX: `esbuild-wasm` runs under a WASM interpreter (slow) — a bundled native
  Swift-side transform or a small JS-based transpiler (e.g. Sucrase-style)
  running in JSC is usually a better fit. `esbuild`'s native Go binary cannot run
  on iOS.
- `npm install` of packages with native addons: **not feasible.** Pure-JS deps can
  be vendored or fetched as source (treated as user data), but anything compiling
  to a `.node` binary is out.

**Python — feasible with real limits.**
- Embedding is a **solved, shipping** path: PEP 730 makes iOS a Tier 3 CPython
  platform (3.13+), and BeeWare's `Python-Apple-support` provides ready
  `Python.xcframework` builds; PythonKit bridges Swift↔Python.
- Hard iOS constraints that the proposal must absorb:
  - **No `os.fork`, no `subprocess`, no `multiprocessing` (process-based).** Many
    libraries assume these. This also means Python "can't shell out."
  - **Binary wheels must be repackaged**: each `.so` must become an individually
    code-signed `.framework` inside the app at *build* time. You cannot
    `pip install` a compiled package **at runtime** — there is no on-device
    compiler and you cannot `dlopen` a downloaded binary. So `installPackage()`
    for Python effectively means "from a pre-vetted, pre-built, bundled catalog,"
    not "anything on PyPI."
  - Pure-Python packages *can* be fetched as source and imported (they're data),
    but the moment a dependency needs a C extension, it must have been built and
    bundled ahead of time.
- The "Embedded WASM Python" alternative inherits the WASM interpreter speed
  penalty; it eases nothing about the wheel problem and is slower. Prefer native
  CPython.

**WASM — feasible, slow.**
- Pure-interpreter runtimes (WasmKit) work and are great for *sandboxing* untrusted
  modules against the VFS via WASI shims. They are **not** a performance play on
  iOS because of the no-JIT rule.

**Structured concurrency / streaming output** via `AsyncStream` is a good,
idiomatic fit. One nuance: CPython embedding is single-interpreter and GIL-bound;
"its own concurrent context" per runtime means an actor/serial-queue wrapper, not
true parallel Python.

### 3. Tooling Layer

**Editor backend — feasible, but not via LSP on-device.**
- **SourceKit-LSP is not available on iOS** (no on-device Swift toolchain). The
  proposal's "integrate SourceKit-LSP for Swift" doesn't hold on device.
- Realistic stack: **tree-sitter** (C, easy to bridge) for syntax highlighting,
  folding, structure, and lightweight diagnostics; per-language linters only where
  they can run in a bundled interpreter (e.g. a Python linter in embedded
  CPython). Rich semantic diagnostics for compiled languages require a remote
  build host.
- `applyEdit`/`getDiagnostics`/`getFileContext` as agent-callable methods is clean
  and feasible.

**Terminal dispatcher — feasible, but it is not a real shell.**
- There is **no `/bin/sh`, no `fork`/`exec` of arbitrary binaries** on iOS. A
  "terminal" here is an **in-app command dispatcher** that maps a curated command
  set to native code or to a `RuntimeEngine`. This is exactly the a-Shell model
  (it reimplements coreutils + bundles interpreters via `ios_system`).
- So `run_terminal_command` must be a **whitelist** (your built-ins + `git` +
  `python`/`node` entrypoints), not arbitrary shell. This is fine and shippable,
  but the proposal's framing as a general terminal overpromises.

**Git (libgit2) — feasible and strong.**
- Mature path: `libgit2` via SwiftGit2 / ObjectiveGit. `init/add/commit/branch/
  merge/status/diff/log/reset` are fully local and fast.
- `clone/push/pull` over **HTTPS** work well (PAT or OAuth token from Keychain).
  **SSH** requires libssh2 compiled in (doable; more build effort). Working Copy
  is the existence proof that full git on iOS is solid.
- This is the *most* directly portable concept from the proposal.

### 4. Agentic Intelligence Layer

**Orchestrator + tool calling — feasible.** Gathering local context (open file,
git status, diagnostics, recent output, tree) and exposing a local tool registry
is straightforward Swift. The agent loop is provider-agnostic.

**Cloud backends — feasible and easy.** `URLSession` streaming (SSE) to Grok /
Anthropic / OpenAI-compatible / Cursor endpoints; keys in Keychain. Note: "Cursor
ACP" should be validated against whatever the current ACP/agent protocol actually
exposes for third-party clients — treat it as "subject to provider terms," not a
given.

**Local LLM (llama.cpp + Metal) — feasible within a tight budget.**
- llama.cpp's Metal backend is mature on Apple silicon. Bridge the C API via a
  Swift package / cinterop.
- **Memory is the binding constraint**, not compute:
  - Use **mmap** model loading (clean, file-backed pages) — mandatory to avoid
    jetsam kills.
  - Realistic on phones: **1B–4B params at Q4_K_M** (~1.8–2.3 GB resident incl.
    KV cache for ~4K ctx). 7B+ is iPad-Pro/M-series territory and still risky.
  - Add `com.apple.developer.kernel.increased-memory-limit` and/or
    `extended-virtual-addressing` entitlements; drop KV cache on memory warnings;
    unload weights on background.
  - Expect single-to-low-double-digit tokens/sec and thermal throttling on
    sustained use. Good for "local quick edits," not for long agentic chains.
- Net: the proposal's "private, offline, fast local edits" is achievable for
  *small* models and *short* tasks; "fast" is relative.

### 5. Persistence & State — feasible

SwiftData/Core Data for project metadata, Keychain for keys/credentials,
per-project on-disk conversation history, and file-watch-driven sync are all
standard. No concerns. (Keychain is the right, expected home for BYO API keys.)

### 6. Native Platform Integration — feasible

Metal for inference, C FFI for libgit2/CPython/WASM, iPad multitasking / Stage
Manager / external keyboard / hardware-keyboard shortcuts (`UIKeyCommand`) are all
well-supported. **Recurring risk: the per-app memory ceiling** (varies by device;
~5 GB-ish on recent iPads with entitlement, less on phones) — every heavy
subsystem (Python heap + model weights + editor buffers) competes for it.

## Corrections to specific proposal claims

| Proposal claim | Reality on iOS App Store |
| --- | --- |
| "JavaScriptCore (full JIT)" | Interpreter-only; no JIT for third-party processes |
| "TS/JSX via esbuild-wasm" | Runs, but under a slow WASM interpreter; esbuild native binary can't run |
| "PythonKit … native bytecode VM, fast" | Works (PEP 730), but **no subprocess/fork**, single-GIL; "fast" ≈ desktop-Python-ish, not free of limits |
| "`installPackage()` / pip / npm" | No runtime install of compiled packages; bundle a pre-built catalog; pure-source deps only at runtime |
| "WASM runtimes" for extra languages | Fine for sandboxing; interpreter-only, slow |
| "Integrate SourceKit-LSP for Swift" | Not available on device; use tree-sitter + bundled linters |
| "Terminal Dispatcher … interactive sessions" | No real shell/PTY; curated built-in command set only |
| "Security-scoped bookmarks so the app retains permission" | Only for *external* URLs; the app's own container needs none |
| "Strong Isolation … agent cannot escape" | App-sandbox-enforced + your path guard; not kernel per-project isolation |
| "Local models … None [auth]" | Correct, but gated by memory; small quantized models only |

## Risk register

| Risk | Severity | Mitigation |
| --- | --- | --- |
| App Review rejection under 2.5.2 | High | Lean into the IDE/scripting carve-out; bundle all interpreters; keep user code visible/editable; no remote code that alters the app; no extension storefront |
| No JIT → slow JS/WASM/Python | Medium | Set expectations; use native code for hot paths; offer remote runtime fallback |
| Runtime package installs impossible | High (UX) | Ship a curated pre-built package catalog; clearly scope "install"; use remote runtime for arbitrary deps |
| Memory jetsam kills (LLM + Python) | High | mmap, small quantized models, entitlements, KV-cache eviction, background unload |
| No subprocess/real shell | Medium | Reframe terminal as command dispatcher; reimplement needed coreutils |
| Scope (ground-up native rewrite) | High | Phase it; reuse only concepts, not Mouse's TS code; consider hybrid with existing remote model |
| SSH/auth for git remotes | Low-Med | Start HTTPS+token; add libssh2 later |

## Recommended path (phased, MVP-first)

1. **Native shell + VFS + editor + libgit2.** Offline editing, file tree,
   tree-sitter highlighting, and full local/remote git. This alone is a credible,
   shippable product (a "Working Copy + editor").
2. **Agent orchestrator with cloud backends only.** Tool registry over the VFS +
   git + editor. Keys in Keychain. This delivers the "agentic" promise with the
   least risk (no on-device inference, no exotic runtimes).
3. **JavaScriptCore runtime** with a scoped Node shim — first real on-device
   execution; lowest-friction interpreter.
4. **Embedded Python** (PEP 730 build) with a **bundled package catalog**, no
   runtime wheel installs.
5. **Local llama.cpp + Metal** for small models, behind clear device/memory gates.
6. **WASM** last, for sandboxing additional languages where speed isn't critical.
7. **Optional remote runtime** (reuse Mouse's Codespaces/relay model) for anything
   on-device can't do — preserving the hybrid story end-to-end.

## Conclusion

The vision is **achievable and has direct App Store precedents**, but it is a new
native product rather than an evolution of the current Capacitor/Codespaces client,
and it must be designed around two hard iOS realities: **no third-party JIT** and
**no runtime installation of compiled code**. With those corrections — interpreter-
only runtimes, a bundled package catalog instead of live `pip`/`npm`, tree-sitter
instead of LSP, a command dispatcher instead of a real shell, and small mmap'd
quantized models — every layer in the proposal maps to a known, shippable iOS
implementation. The highest-confidence, highest-value core (editor + git + cloud
agent) can ship first; the riskier on-device execution and local-inference layers
can follow behind clear capability and memory gates, with a remote runtime as the
escape hatch for workloads iOS fundamentally cannot host.
