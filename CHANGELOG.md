# Changelog

All notable changes to Mouse. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[SemVer](https://semver.org/) (`MAJOR.MINOR.PATCH`), pre-1.0 so minors may
carry breaking changes.

## [Unreleased]

### Added
- Node layer: `readable.unpipe()` works — it was a TypeError, so a pipe could be started but
  never stopped. Adds `wrap`, `compose`, `setDefaultEncoding` and the stream introspection
  getters; `writableLength` now counts the chunk still in flight, so it agrees with
  `writableHighWaterMark`.
- Node layer: the console is complete. Sixteen methods were missing from the global
  console — `dir`, `table`, `group`, `count`, `time`, `assert` and more — so `console.dir(x)`
  threw and killed the program; `console.debug` wrote to stderr instead of stdout; and the
  `Console` class had silent no-op stubs. One implementation now backs both, with real
  `table` box drawing and group indentation.
- Node layer: `console.log`/`util.inspect` format the way node's do. `Map`, `Set`, `Date`,
  `RegExp` and `Promise` printed as `{}`; circular references expanded instead of being
  marked; long collections were never truncated; class names, `-0`, BigInt `n`, typed arrays,
  sparse holes, symbol keys and null prototypes were all wrong. Getters are now reported as
  `[Getter]` rather than CALLED — inspecting an object could run a side effect. `%d` uses
  Number, and a lone string is no longer processed, so `console.log('100%% off')` keeps its
  percent sign.
- Node layer: `base64url` works — it was not implemented at all, so
  `Buffer.from(token, 'base64url')` returned the token's own bytes. Also fixed:
  `utf16le`/`ucs2` ignored by `Buffer.from`, `ascii` not masked (and asymmetric in node —
  0xff encoding, 0x7f decoding), and `StringDecoder` holding no state, so a character split
  across writes became replacement characters.
- Node layer: two events that never fired now do. A failed `fs.createReadStream` emits
  `'close'` after `'error'`, and a `ClientRequest` emits `'close'` when its response ends —
  it had been tied to the socket closing, which keep-alive outlives.
- Node layer: fs errors carry node's `code`, `syscall` and `path`, and five operations now
  fail where node fails instead of silently succeeding. `rmdirSync` on a file deleted it,
  `writeFileSync` into a missing directory created the tree, and `mkdirSync` built a whole
  path without `recursive`. Reading a directory is EISDIR and scanning a file is ENOTDIR.
- Node layer: every cancellable API now cancels. Eight accepted an `AbortSignal` and
  ignored it — `timers/promises.setTimeout`, `events.on`, `stream.finished`,
  `stream/promises.pipeline`, `readline.createInterface`, `fs.readFile`,
  `fs.promises.readFile` and `fs.watch` — and five of those turned a cancellable wait into
  a permanent one.
- Node layer: `fs.createReadStream({start, end})` reads the byte range it was given
  instead of the whole file, and honours `highWaterMark`. Also fixed:
  `events.once(..., {signal})` (an ignored signal never settled the promise),
  `util.inspect(value, {depth})` in its options form, `querystring.parse` `maxKeys`, and
  `createCipheriv` `authTagLength`.
- Node layer: `http.request`/`get` honour an `AbortSignal`. It was accepted and ignored,
  so a caller's only way to cancel became a permanent wait — an unabortable request.
- Node layer: `spawnSync` honours `encoding` and `cwd`; `input`, `timeout`, `maxBuffer`
  and `killSignal` now throw with a reason instead of being silently ignored, since a
  synchronous run reports what a command produced rather than a live process.
- Node layer: seven silently-ignored options now work. Two were destructive:
  `fs.writeFileSync(..., {flag:'a'})` truncated the file instead of appending, and
  `fs.rmSync(dir)` without `recursive` deleted the whole tree where node refuses. Also
  fixed: `{mode}` on writeFile/mkdir (a secret was left world-readable),
  `fs.readdirSync({recursive:true})`, `rmdirSync` on a non-empty directory,
  `new Writable({highWaterMark})` (backpressure was never signalled), and zlib `{level}`.
- Node layer: `TextDecoderStream` and `TextEncoderStream` exist, and `TextDecoder` can
  actually stream — it ignored its options argument, so `{stream: true}` was a silent
  no-op and a character split across chunks decoded to replacement characters. Adds
  `fatal`, `ignoreBOM` and `TextEncoder.encodeInto`.
- Node layer: `http.Server` gained `closeIdleConnections()` and `closeAllConnections()`.
  They act without closing the listener, and differ as node's do — an in-flight request
  survives the first and dies to the second.
- Node layer: node 17+'s stream operators are real — `map`, `filter`, `flatMap`, `take`
  and `drop` return streams; `forEach`, `toArray`, `reduce`, `some`, `every` and `find`
  return promises; plus `iterator([options])`. Matches real node including the edge
  cases: unseeded `reduce`, and `every`/`some` inverting on an empty stream.
- Node layer: `crypto`'s `Hash`, `Hmac` and `Cipher` are real Transform streams, so
  `fs.createReadStream(f).pipe(hash)` works. A spent hash now reports
  ERR_CRYPTO_HASH_FINALIZED instead of digesting twice.
- Node layer: `Readable.read()` is binary-safe. It decoded each chunk as UTF-8 into a
  string and re-encoded — lossy for any non-text data — and ignored which encoding
  `setEncoding` requested. The 'data' path was always correct, so only `read()` callers
  were affected.
- Node layer: Buffer gained 35 missing documented methods — `writeFloatBE/LE` and
  `writeInt16BE/LE` (whose readers were already present), signed `BigInt64`, the
  variable-width integer family over 1..6 bytes, `swap16/32/64`, node's lowercase
  `uint` aliases and `Buffer.copyBytesFrom`. All byte-exact against real node.
- Node layer: the `dns.resolve*` family is real (`swift/Mouse/NodeDNS.swift`) — TXT, MX,
  NS, CNAME, PTR, SOA, SRV, NAPTR, CAA, `resolveAny`, `reverse` and `lookupService`,
  through the system resolver in libresolv. Verified against real node on live records.
  `resolveTlsa` still refuses: a DANE hash needs a TLS stack that can consume it.
- Node layer: brotli is real (`swift/Mouse/NodeBrotli.swift`) — one-shot and streaming,
  through Apple's Compression framework, which has had COMPRESSION_BROTLI since iOS 15.
  The refusal claimed brotli was not on the device. zstd genuinely is absent and keeps
  refusing. Verified by each engine reading what the other writes.
- Node layer: `crypto.generateKeyPairSync` raises ERR_INVALID_ARG_TYPE for a missing
  type instead of refusal language, which had made a healthy function read as
  unavailable to a surface audit.
- Node layer: `crypto.diffieHellman` works — node's key-object agreement over X25519
  and the EC curves. Its refusal cited the bignum that finite-field DH needs, which is
  a different function; the capability was already present via CryptoKit. Adds X25519
  key generation, and `keyIdentify` now tells X25519 from Ed25519 by OID (same wrapper
  shape and same 32 bytes, so length cannot). Verified by a cross-engine exchange where
  node and this engine each hold half the pair and derive the same secret.
- Node layer: `fs.glob`/`fs.globSync` are real — brace expansion, `**`, character
  classes and node's dotfile rules, returning node's exact file lists on a real tree.
  `path.matchesGlob` and glob's `exclude` option stay refused, each naming a measured
  inconsistency in node's own experimental implementation rather than a general worry.
- Node layer: `crypto.scrypt`/`scryptSync` are real (`swift/Mouse/NodeScrypt.swift`).
  scrypt is not a primitive — it is PBKDF2-HMAC-SHA256 around a Salsa20/8 memory-hard
  mix — so it needed no system implementation. Matches RFC 7914's published vectors
  byte for byte, along with node's option aliases, defaults and `maxmem` rules.
- Node layer: one `MessagePort` with both surfaces — the `MessageChannel`,
  `MessagePort` and `BroadcastChannel` globals are now the `worker_threads` classes,
  as node has them, so `receiveMessageOnPort` works on a global channel's port.
- Node layer: `process.nextTick` now really does run before promise reactions. It is
  scheduled as a microtask, so it previously won only when registered first; every
  host-invoked callback now drains the tick queue before the stack unwinds — the
  loop's phases plus all nine bridges that call JavaScript from their own handler.
  `dns.lookup` completions and `fs.watch` events were running promises first.
- Node layer: MessagePort deliveries run in their own event loop phase (after
  nextTick and promises, before immediates), which is where node runs them.
- Node layer: `BroadcastChannel` (global and via `worker_threads`),
  `receiveMessageOnPort` and `get`/`setEnvironmentData` work. Both had been refused as needing shared memory; a
  broadcast is a name registry with fan-out through the main engine as hub, and the
  synchronous drain pops a queue the port already holds. A MessagePort with no
  listener now queues instead of dropping, and an open channel holds the event loop
  as node's does. environmentData is inherited data, not shared data: a worker gets a
  snapshot at spawn time and never sees a key set afterwards, which is node's rule.
- Node layer: `cluster` works. The primary binds one listening socket and hands
  each accepted descriptor to a worker, which adopts it as an ordinary connected
  socket; worker lifecycle, `disconnect()` and the `online`/`listening`/`exit`
  events are real. Verified byte-identical to real node over 25 rounds of a
  shared-port program that kills a worker mid-flight.
- Node layer: `options.env` now reaches spawned children. It was silently dropped,
  so every child inherited the parent's environment regardless of what was passed.
- Node layer: two http failures that used to HANG now error the way node's do — a
  keep-alive socket whose peer hung up leaves the pool, and a request whose socket
  closes before answering emits `ECONNRESET` ('socket hang up') instead of waiting
  forever.
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
  `child_process` bridged into `msh` (plus live `node` children, `fork` with a real
  message channel, and `worker_threads`), the **fetch API** whose response bodies genuinely
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
  **webpack 5** (bundles byte-identically to real node, terser and all),
  **esbuild-wasm** (a compiler in WebAssembly, driven over a live child process), inquirer/prompts, commander/yargs, express routing,
  tar, prettier, and glob. Big bundles cache their transpile,
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
