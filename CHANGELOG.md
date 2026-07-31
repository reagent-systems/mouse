# Changelog

All notable changes to Mouse. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[SemVer](https://semver.org/) (`MAJOR.MINOR.PATCH`), pre-1.0 so minors may
carry breaking changes.

## [Unreleased]

### Added
- Node layer: the rest of the fetch `Request` surface (`mode`, `credentials`, `cache`,
  `referrer`, `referrerPolicy`, `integrity`, `keepalive`, `destination`, `duplex` and the
  navigation flags), and `net.Socket`'s `bufferSize`, `localFamily`, `resetAndDestroy` and
  `server` — the listener that accepted the socket.

- Node layer: the connection and protocol options `http.Server` and `net.Server` record
  (`noDelay`, `keepAlive`, `keepAliveInitialDelay`, `pauseOnConnect`, `highWaterMark`,
  `httpAllowHalfOpen`, `maxRequestsPerSocket`, `requireHostHeader` and the rest); real
  `bytesWritten`/`bytesRead` counters on the zlib coders; `StringDecoder`'s `lastNeed`,
  `lastTotal` and `lastChar`; and `MessagePort.hasRef()`/`onmessageerror`.

- Node layer: `readableAborted`, `readableDidRead` and `writableAborted` on streams — the
  getters that distinguish a stream destroyed mid-flight from one that ran to completion.

- Node layer: `process.prependOnceListener`, `fd`/`readable`/`writable` on `process.stdout`,
  `stderr` and `stdin`, and `Response.formData()` — which reads urlencoded and multipart bodies,
  taking the multipart boundary from the Content-Type header. It was the only body reader
  missing from the fetch set.

- Node layer: `process.threadCpuUsage`, `process.finalization` and `process.assert`; and
  `process.dlopen`/`process.execve` refuse by name with the reason (no executable mapping, no
  exec) instead of being absent.

- Node layer: `util.MIMEType` and `util.MIMEParams` — parsing, parameter get/set/delete,
  iteration, and a `toString` that re-quotes values containing separators so a reassembled type
  parses back the same way. Plus `util.parseEnv`, `util.getCallSites`, `util.diff`, and
  `events.EventEmitterAsyncResource` with `kMaxEventTargetListeners`. All were named by the
  module-surface audit and are documented API, not the node internals they sat beside.

### Fixed
- Node layer: `process.on('exit')` and `process.on('beforeExit')` fire. They never did, so any
  cleanup registered there — flushing logs, writing coverage, removing lockfiles — was silently
  skipped. `beforeExit` re-fires when a handler schedules more work and does not fire after an
  explicit `process.exit()`; `exit` runs last and synchronously with the final code.

- Node layer: `querystring` handles repeated keys as arrays rather than keeping only the last
  value, decodes `+` as a space, repeats the key when stringifying an array instead of joining
  with commas, writes `null` as empty, honours the separator/equals arguments, and survives a
  malformed percent-escape instead of throwing.

- Node layer: `url.resolve()` handles a base that is only a path — it returned the relative part
  alone, discarding the base. And `url.urlToHttpOptions()` reports `hash`, `search`, `pathname`
  and `auth`, with `port` as a number, so options built from a URL keep its credentials.

- Node layer: `url.parse()` is a real parser rather than one regex. A bare path parsed to `/`,
  `user:pass@host` put the user in `hostname`, `mailto:` returned nulls, and `host`, `hash` and
  `path` were never populated at all. 13 vectors match node, including IPv6 literals and the
  `//host/path` case that stays a path without a protocol.

- Node layer: `Symbol.toStringTag` on `process` and the web globals, so
  `Object.prototype.toString.call(x)` reports what node reports. Libraries detect the
  environment this way — axios was silently choosing its fetch adapter over the Node http one,
  bypassing every configured agent.
- Node layer: `url.format()` keeps the port when given `hostname`/`port` rather than `host`,
  emits `//` only for slashed protocols, and honours `auth`, `query` and `hash`. The dropped
  port sent redirects to port 80.
- Node layer: a client response carries `.req`, and the implicit `Host` header is readable
  through `getHeader` rather than only written to the wire. Both are what `follow-redirects`
  needs, so **axios follows redirects**.

- Node layer: `https.globalAgent` reports `https:` and port 443. Both protocol modules built
  their agent with the same defaults, so the https one claimed `http:` and 80 — a wrong value
  a caller would act on rather than an error it could catch.

- Node layer: a custom `http.Agent` is honoured. The client tested for an internal field before
  accepting one, so every subclass — including every proxy agent — was silently replaced by the
  global agent and the request went direct. An agent that overrides `createConnection` now
  decides where the request connects, and the lifecycle hooks (`keepSocketAlive`, `reuseSocket`,
  `removeSocket`) are called rather than merely defined. Adds `defaultPort`, `protocol`,
  `maxTotalSockets` and a live `totalSocketCount`.

- Node layer: `process.stdout` and `stderr` are `Writable`s and `process.stdin` is a `Readable`
  — they were plain objects, so every `instanceof` check against them was false and code
  branched the wrong way. Behaviour is unchanged; only the prototype was missing. Also,
  `isTTY`/`columns`/`rows` are now absent rather than `false` when output is not a terminal,
  as node has it.

- Node layer: `process.cpuUsage()` reports real CPU time from `getrusage`. It returned hardcoded
  zeros, which is worse than absent — a caller measuring CPU saw a working API report nothing.

- Node layer: `zlib.BrotliCompress`/`BrotliDecompress` exist as classes, so `new
  zlib.BrotliCompress()` works rather than throwing — brotli had only the factory functions.
  And `createGzip() instanceof zlib.Gzip` is now true, as node has it; the factories returned a
  plain Transform, so every `instanceof` check against a coder class was false.
- Terminal: leaving the alternate screen restores what was there. `ESC[?1049h`/`ESC[?1049l`
  is a save/restore pair, but entering cleared without saving and leaving cleared again — so
  quitting `less`, `top` or any full-screen program wiped the terminal instead of returning the
  user to their work. The cursor is restored too, and wide characters survive with their column
  spans intact.
- Terminal: wide characters occupy two columns. CJK, Kana, Hangul, fullwidth forms and emoji
  were given one cell each, so every TUI drawing aligned or boxed output with non-Latin text
  came out progressively crooked. A wide character now reserves a continuation cell, wraps whole
  at the right edge instead of splitting, and clears its partner when either half is overwritten;
  a lone combining mark attaches to the character already on screen rather than taking a column.
- Node layer: `structuredClone`, worker `postMessage` (both directions), `workerData`,
  `setEnvironmentData` and the engine-to-engine IPC wire all use the real structured clone.
  Each was a JSON round-trip, so a `Map` posted to a worker arrived as `{}` — silently. node
  defines every one of these in terms of the structured clone algorithm.

### Added
- Node layer: `v8.serialize`/`deserialize` are a real structured clone, replacing
  `JSON.stringify`. Map, Set, Date, RegExp, Buffer and typed arrays survive; `undefined` stays
  distinct from `null`; BigInt, `NaN`, `Infinity` and `-0` round-trip; cycles and shared
  references are preserved rather than duplicated or thrown on. Adds `v8.Serializer`/
  `Deserializer`. The format is this engine's own, not V8's wire format — a process serializes
  for itself — so a cache written by real node is not readable here, and vice versa.
- Node layer: **jest runs with its cache enabled**, cold and warm. The cache was what hung it:
  a haste map is mostly Maps and Sets, and JSON discarded them silently.
- Node layer: **`vm` contexts are real.** `createContext`, `runInContext`, `runInNewContext`,
  `compileFunction` and `Script.prototype.runInContext` work against a genuine separate global —
  a second `JSContext` in the engine's virtual machine, with the sandbox's keys bound as live
  accessors so reads and writes stay live in both directions. 18 behaviours match node.
- Node layer: **jest runs**, reporting the same passes, failures, pending tests and counts as
  real node, with each test file executing inside a vm context. Set `cache: false` — with jest's
  haste-map cache enabled the run does not settle here, which is an open lead.
- Node layer: `require.resolve.paths(request)` — the directories that would be searched.
- Node layer: the `module` core module is real, growing from three exports to node's surface:
  `_cache`, `_extensions`, `_nodeModulePaths`, `_resolveFilename`, `_load`, `_resolveLookupPaths`,
  `wrap`/`wrapper`, `globalPaths`, a `Module` constructor with `require`/`load`/`_compile`, and a
  complete `builtinModules`. Tools that build their own module registry on node's read these.
- Node layer: a child process emits `'spawn'`, and a msh-bridged child emits `'exit'` before
  `'close'` rather than after. The order was reversed and `'spawn'` was never emitted at all, so
  code waiting on either — jest's file crawler waits on `'exit'` — could wait forever.

### Fixed
- Node layer: `vm.createContext` returned the sandbox unchanged while `runInContext` was absent,
  so a feature check saw a working `vm` and then got a bare TypeError. The context-based
  functions now refuse by name with the real reason. `runInThisContext` and `createContext`
  keep working — the latter because webpack depends on it.
- Node layer: **finite-field Diffie-Hellman is real** — `createDiffieHellman`,
  `createDiffieHellmanGroup` and `getDiffieHellman` with all eight MODP groups (RFC 2409 and
  RFC 3526), on JavaScriptCore's native `BigInt`. Real node and this engine derive the same
  2048-bit shared secret from opposite halves of an exchange.
- Node layer: `crypto.generatePrime`/`generatePrimeSync` and `checkPrime`/`checkPrimeSync`,
  including safe primes, the `add`/`rem`/`bigint` options, and Miller-Rabin that rejects
  Carmichael numbers. All four were refused as "needs a bignum implementation"; the bignum was
  in the engine the whole time.

### Changed
- The remaining refusals were audited by MEASURING the platform claim each rests on, rather
  than reading headers. zstd's refusal survives (measured absent). The TLS-server refusal keeps
  standing but its stated reason is wrong — Network.framework has the pieces. corecrypto has
  X448 and bignum symbols, but they carry no ABI guarantee and are not usable.
- Node layer: **unhandled promise rejections exit 1**, as node's do, and
  `process.on('unhandledRejection', …)` is honoured — a listener suppresses the exit and may
  set its own code. Fires for a bare rejection, an awaited one, and a throw inside an async
  function; silent when a handler is attached. Uses JavaScriptCore's
  `JSGlobalContextSetUnhandledRejectionCallback`, resolved with `dlsym` and guarded, so a
  system without the symbol keeps the previous behaviour. The symbol is SPI — see system.md §8
  for the App Store consideration and the single seam that removes it.
- Node layer: **mocha 10 runs a suite**, reporting the same passes, failures, pending tests,
  timeouts and exit code as real node.
- Node layer: `process.exitCode = n` is honoured. It was a property nothing ever read back, so
  a program that reports failure by setting it — every test runner and most linters — exited
  **0** on failure. A bare `process.exit()` now adopts it too, as node's does.
- Node layer: `assert` throws a real `AssertionError` carrying node's `code`, `operator`,
  `actual`, `expected` and `generatedMessage`. Failures used to be bare `Error`s, so a test
  runner had nothing to build a diff from. Messages are byte-identical to node's, including
  the `+ actual - expected` diff bodies.
- Node layer: deep equality is real, replacing `JSON.stringify` comparison in all three places
  that used it (`assert.deepStrictEqual`, `assert.deepEqual` — which was merely aliased to the
  strict form — and `util.isDeepStrictEqual`). Key order no longer decides equality; `NaN`
  equals itself; `Map`, `Set`, `Date`, `RegExp` and typed arrays compare structurally; a key
  holding `undefined` is distinct from a missing key; circular structures compare instead of
  throwing; and the loose form is genuinely loose.
- Node layer: `assert.throws`/`doesNotThrow` honour their expected-error argument — a regular
  expression, an error class, or a property matcher. It was ignored, so a test asserting a
  specific error passed on ANY throw. Adds the async `assert.rejects`/`doesNotReject`.
- Node layer: **eslint 9 runs**, reporting the same findings on the same files as real node.
  A real-package proof exercises capabilities in combination, and this one found four defects
  no per-API sweep had.
- Node layer: `process.hrtime` reads a MONOTONIC clock. It was built on `Date.now()` — wall
  clock, millisecond resolution, and free to run backwards across a clock correction, so a
  duration could come out negative. It now carries the `bigint` property too, as an own
  property callable unbound. `performance.now()` moved to the same clock and is fractional.
- Node layer: `url.pathToFileURL`/`fileURLToPath` are real rather than string surgery — paths
  are percent-encoded and decoded, non-file schemes and foreign hosts are rejected with node's
  error codes, and 38 vectors are byte-identical to node's.
- Node layer: three `URL` defects. An empty authority lost its slashes (`file:///a` became
  `file:/a`), the pathname was never percent-encoded, and `origin` reported the scheme where
  node reports `null`. `searchParams` is now LIVE — mutating it rewrites `search` and `href`,
  where before it was a detached copy and the change vanished.
- Node layer: `import()` accepts a `file://` URL specifier, and a query on one busts the
  module cache instead of silently returning the stale module — which is what the query is for.
- Node layer: `crypto.privateEncrypt`/`publicDecrypt` work — the legacy direction where the
  private key seals and the public key opens. SecKey's RAW algorithms do it; only the PKCS#1
  type 1 padding was missing. Verified cross-engine against real node in both directions.
- Node layer: `for await (const chunk of process.stdin)` works — stdin had no async
  iterator, so the standard way to read piped input threw. Piped stdin now emits `'end'`
  when there is no more input, as node's does; `process.stdin` gained `push` and the stream
  operators, and `process.stdout`/`stderr` gained `destroy`/`setDefaultEncoding`.
- Node layer: streams auto-destroy when finished, as node's have since v14, so
  `stream.destroyed` is finally a reliable "done with this" flag. `destroy()` now clears
  `readable`/`writable` too. A Duplex waits for both halves.
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
