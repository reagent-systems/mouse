# Changelog

All notable changes to Mouse. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[SemVer](https://semver.org/) (`MAJOR.MINOR.PATCH`), pre-1.0 so minors may
carry breaking changes.

## [Unreleased]

### Added
- **Android app** (`kotlin/`) at feature parity with iOS, native Kotlin +
  Compose: the gesture shell, onboarding with idle "motion is the arrow"
  animations, GitHub sign-in, workspaces (native tar/gzip), Files/Viewer/
  Graph, push/pull, persistence, and a terminal with `msh` + the real
  system `sh` behind the engine switcher.
- **`msh` shell** on both platforms: quoting, variables, globs, pipes,
  redirection, `&&`/`||`, history, and ~50 built-ins (incl. `sed`, `diff`,
  `base64`, checksums).
- **`node` is real** — a Node-compatible runtime on JavaScriptCore, so the
  terminal runs actual npm software on the phone. `npm install <pkg>` then
  `<bin>` works: the CommonJS *and* ES-module systems, a real event loop,
  `fs` (sync, callback and fd forms), `stream` (with streaming
  compression), `crypto` (CryptoKit — including real AES-GCM/CBC/CTR and
  ChaCha20-Poly1305 ciphers, `pbkdf2`, `hkdf`, and RSA/EC/Ed25519 signing, all interoperable with
  node's — `jsonwebtoken` issues RS256, PS256, ES256 and HS256 tokens real node
  accepts), `zlib` (libz), `readline`,
  `child_process` bridged into `msh`, the **fetch API** whose response bodies genuinely
  stream (server-sent events arrive as they are sent, not all at once at the
  end), and **real TCP** (`net`): outbound connections, servers
  that listen and accept, honest backpressure and half-close — verified in
  both directions against real node, so a node client cannot tell our
  server from node's. On top of that, **`http.createServer`** — keep-alive,
  pipelining, chunked bodies, response bytes identical to node's — which
  means **express apps serve requests from the phone** — and the HTTP client
  moved onto raw sockets too, so response bodies stream in as they arrive and
  protocol upgrades work: **real WebSockets** through the genuine `ws`
  package, in both directions — plus the standard `WebSocket` global, which
  reaches `wss://` endpoints. **File watching is real too** (`fs.watch` on
  kqueue), so `chokidar` — what every `--watch` mode is built on — reports the
  same events as under real node. Full-screen programs get a real TTY: keystrokes,
  arrows/F-keys/Ctrl-combos, bracketed paste, resize as `SIGWINCH`, and
  terminal query replies — so **ink/React TUIs draw on the terminal
  screen**. Verified against real `node` (65 byte-identical fixtures) and
  by running the genuine articles: the Anthropic SDK with token streaming,
  TypeScript's `tsc` (`--watch` included — edit, recompile, diagnostics),
  **webpack 5** (bundles byte-identically to real node, terser and all), inquirer/prompts, commander/yargs, express routing,
  tar, prettier, glob, and esbuild-wasm. Big bundles cache their transpile,
  so a 9 MB CLI relaunches in a fifth of a second.
- **`npm` / `npx` / `pnpm`**: real registry resolution (full semver),
  integrity-checked tarballs, native unpacking, and a Node-compatible
  `node_modules` layout — resolution verified identical to `pnpm`.
- **Networking in the terminal**: `ping` (real ICMP), `curl`/`wget`,
  `sleep`, on async streaming-command machinery; any keypress interrupts a
  streaming command (the phone's Ctrl-C).
- Shared live `FileBuffer`s — rings viewing the same file share one document.
- Release + CI workflows building both apps.

### Fixed
- Selection-handle drags no longer drive the lane (CPU spike) — the shell
  stands down while the editor is focused.
- Lazy edge-panel mounting removes the edge-swipe memory doubling.

<!--
Release process: see RELEASING.md. When cutting a release, rename
[Unreleased] to the version + date and start a fresh [Unreleased] section.
-->
