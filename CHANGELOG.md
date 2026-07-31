# Changelog

All notable changes to Mouse. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[SemVer](https://semver.org/) (`MAJOR.MINOR.PATCH`), pre-1.0 so minors may
carry breaking changes.

## [Unreleased]

### Added
- Node layer: **a stack trace out of a bundle names the author's file and line**. Any loaded
  file's `//# sourceMappingURL` is honoured — inline `data:` URI or a `.map` beside it — which
  node does only under `--enable-source-maps`; here it is the default, because a trace into line
  4000 of a bundle says nothing. Verified against node with that flag, on a bundle esbuild built
  on this engine.
- Node layer: an uncaught error prints node's source-context header — the file, the line, that
  line's own text and a caret — above the stack. A trace says where; this says what is there.
- Node layer: `NAPI_RS_FORCE_WASI` is set by default. napi-rs generates a loader that tries the
  platform's `.node` and falls back to the package's WebAssembly build only when told; on iOS
  the native branch can never load, so the fallback is the only reachable one. Without it a
  package like oxc-parser never attempted its portable build at all. Both oxc-parser and
  rolldown now install and reach theirs, and both stop at wasm threads — their builds declare
  shared memory, which JavaScriptCore will not parse. Gated on both packages.
- Node layer: **`node:wasi`** — WASI preview1 over the engine's own fs. Args, environ, both
  clocks, `random_get`, the fd family (read/write/seek/tell/fdstat/filestat/readdir/close), the
  path family (open/filestat/mkdir/rmdir/unlink/rename), preopened directories, and rights
  enforcement — a descriptor carries the capabilities it was opened with and an operation
  outside them is `ENOTCAPABLE`, as node's is. Verified against node's own WASI on a wasm module
  assembled by hand for the purpose. A napi-rs package's wasm build now loads as far as its own
  threading: rolldown's is compiled with shared memory, which JavaScriptCore will not parse, and
  that wall has its own gate — the `Memory` constructor accepts `shared: true` and silently
  returns ordinary memory, so feature-detecting on it would miss the problem.
- msh: **`npm create <starter>`** (and `npm init <starter>`, and bare `npm init` to write a
  package.json) — npm's rule that `create vite` runs `create-vite`, so `npm create vite@latest
  app -- --template vanilla-ts` scaffolds a real project on the phone.
- Package manager: a napi-rs package's `-wasm32-wasi` optional binding is installed — the
  author's own portable build for platforms they ship no binary for, the same principle as the
  rollup and esbuild substitutes in the shape napi-rs uses. It loads as far as `node:wasi`,
  which this engine does not have; the first-run gate pins that so it cannot rot.
- msh: **`npm run <script>`** (and `npm test`/`start`/`stop`/`restart`, plus bare `npm run` to
  list). Scripts run as ordinary msh programs, so `&&`, pipes and env prefixes behave and a
  long-running script takes the terminal the way it does when typed by hand; `pre`/`post` hooks
  run around the main script, arguments after `--` are appended, the exit status propagates, and
  a missing script says so. The package.json used is the one governing the current directory,
  found by walking up. Verified against real npm on the same package.json.
- Node layer: `SharedArrayBuffer` exists. JavaScriptCore has no such constructor and no option
  turns one on, but its `Atomics` work on an ordinary buffer — so it is one, and the sharing it
  names is where the refusal lives: a buffer crossing to another engine throws `DataCloneError`
  with the reason, rather than arriving as an unrelated copy. Worker pools allocate one per
  worker for their own signalling, so its absence stopped them starting at all.
- Node layer: source compiled at RUNTIME can `import()`. `new Function('s', 'return import(s)')`
  is the standard way to keep a dynamic import out of a CommonJS transpile; the loader's rewrite
  never sees it and JavaScriptCore's own `import` has no module loader.
- Node layer: **`node app.ts` runs TypeScript**, compiled with the project's own `typescript`
  package (`.ts`, `.tsx`, `.mts`, `.cts`, and as an import target), honouring the nearest
  **`tsconfig.json`** — parsed by that same typescript, so comments and `extends` behave — and
  resolving its **`paths` aliases** (`@app/*`), which are a project convention no package
  lookup would find. Verified against `tsx` on real node reading the same tsconfig. Verified line-for-line
  against real node's `--experimental-transform-types` across generics, enums, `satisfies`,
  abstract classes, type-only imports and parameter properties. A project without typescript
  installed is told that, rather than shown a SyntaxError on a type annotation. This is a
  deliberate step BEYOND the node version the engine reports, in the direction node itself
  took in 22.6.
- Node layer: **ES module exports are live bindings**, as node's are. Every export is a getter
  defined before the module body, so a later mutation shows through `import * as ns`, a cycle
  reaching back into a module finds its hoisted function declarations, and a `const` read too
  early throws TDZ exactly where node throws it. A destructured named import remains a
  snapshot — making it live means rewriting every reference, which needs scope analysis — and
  the ESM grammar gate pins that divergence on both sides rather than leaving it unsaid.
- Package manager: **native-binary packages resolve to their authors' WebAssembly builds** —
  `rollup` to `@rollup/wasm-node`, `esbuild` to `esbuild-wasm` — installed under the original
  name, so the package that depends on one is unmodified. iOS can neither load a `.node` addon
  nor exec a downloaded binary, and both projects publish a wasm build in lockstep with the
  native one for platforms in exactly that position. The install line names the substitute.
- Node layer: **vite runs on the engine** — both halves. Its dev server serves transformed
  modules byte-identical to real node's vite, and its production build, rollup doing the
  parsing and bundling in WebAssembly, emits a byte-identical bundle. Rollup's parser is
  normally a native `.node` addon that iOS can never load; rollup's own `@rollup/wasm-node` is
  the drop-in for that case, and the proof uses it on both sides so the comparison is between
  engines, not parsers — and the substitution is the package manager's now, so `npm install
  vite` is all it takes.
- Node layer: **conditional `exports` are resolved by the syntax of the request**, as node does
  — `import` on "import", `require` on "require", and `import()` on "import" even from a
  CommonJS file. **Subpath exports** (`rollup/parseAst`), `*` patterns and array fallbacks now
  resolve, and a package that declares `exports` publishes only what the map names: `main` and
  `index.js` are ignored, and a path outside it fails with node's
  `ERR_PACKAGE_PATH_NOT_EXPORTED`.
- Node layer: `import.meta` is a whole object — `url`, `filename`, `dirname`, `resolve` — rather
  than two string substitutions, so the forms real packages use no longer reach the parser.
- Node layer: **X448 is real** — `generateKeyPairSync('x448')` and `crypto.diffieHellman()`.
  RFC 7748's Montgomery ladder over p = 2^448 − 2^224 − 1 on JavaScriptCore's `BigInt`, with
  node's DER encodings both ways. Verified cross-engine: real node generates one half of an
  exchange and this engine the other, and both derive the same 56-byte secret. The refusal it
  replaces said "no CryptoKit support" — true of the system, and silent on whether the curve
  could be written, the same shape as `scrypt` and finite-field DH.
- Node layer: `dns.resolveTlsa()` returns real TLSA records — `{certUsage, selector, match,
  data}` with the association data as an `ArrayBuffer` — and `dns.resolve(name, 'TLSA')` routes
  to it. Resolving the record never needed the TLS stack that consuming it does.

- Node layer: `worker_threads.moveMessagePortToContext()` works — a port handed into a `vm`
  context posts to its peer and receives through `onmessage` once started, with node's
  web-shaped port and node's `ERR_INVALID_ARG_TYPE` for a non-context.

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
- Node layer: a worker that throws emits `'error'` on the `Worker` with the real exception —
  name, message and stack — before `'exit'`. The parent previously received only exit code 1,
  so it knew a worker had died but not why.

- Node layer: spawning a command that does not exist emits `'error'` with `ENOENT` and closes,
  as node does, instead of reporting exit 127 — which made "not installed" look like "ran and
  failed" to anything checking for a missing binary.

- Node layer: `http.Server` emits `'clientError'` for a malformed request, carrying node's
  `HPE_INVALID_METHOD` code and the socket; with no listener it answers `400 Bad Request` and
  closes, as node does. A bad request line was previously accepted as a message with a nonsense
  method, so the peer was never told and the connection was left open.

- Node layer: `process.emitWarning` emits the `'warning'` event as well as printing, so code
  that attaches a listener to observe or route warnings actually receives them; the `{ type,
  code, detail }` options form works. And `process.on('uncaughtExceptionMonitor')` fires before
  the `uncaughtException` handlers, which is how an error reporter observes without swallowing.

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

### Fixed
- Node layer: `fs.writeSync` honours node's TWO signatures — `(fd, buffer, offset, length,
  position)` and `(fd, string, position, encoding)`. Reading a string call with the buffer
  signature put the bytes at the wrong offset, silently. And `fs.writeFileSync`'s `flag` option
  accepts a number, where reading it as text made every numeric spelling mean "truncate", so an
  append replaced the file.
- Node layer: `fs.openSync` understands NUMERIC flags — `O_WRONLY|O_CREAT|O_TRUNC` as a number
  is how Go's wasm runtime and every WASI shim open a file, and stringifying it gave "1537",
  which reads as neither write nor append. A descriptor now also writes at its own position
  (or the one given) instead of appending, which had been putting content in the file twice.
- Node layer: `Atomics.wait` on a shared buffer says what the wall is — it waits for another
  thread to write memory no separate engine can address — instead of JavaScriptCore's message
  about SharedArrayBuffer, which reads as a type error. esbuild's `buildSync` is this call; its
  `build()` works.
- Node layer: **a TypeScript stack trace names the line in the .ts file**. Erasing types moves
  lines in both directions — an `interface` disappears, an `enum` expands — so the compiler's own
  source map is now requested, decoded, and applied to the source-context header and to every
  frame of the stack.
- Node layer: **stack traces name the right line**. The CommonJS wrapper cost every trace a
  line, the ESM transform's prologue cost four more, and a multi-line import collapsed to one
  line moved everything below it up — so a trace pointed at code that was fine. The wrapper and
  everything the transform adds now share the body's first and last lines, and a replacement
  carries the newlines it consumed. Gated on five shapes against real node.
- msh: `npm install` reads the package.json governing the current directory, not the workspace
  root's, so `cd app && npm install` works after scaffolding — and writes a new dependency back
  to that same file.
- msh: `npm create`'s `--` separator is consumed by npm rather than passed to the scaffolder,
  which read it as the project name.
- Node layer: `node -e "…" value` puts no script path in `process.argv` — argv[1] is the first
  real argument, as node's is. A phantom path made every `node -e` script read the wrong one,
  which is most of what npm scripts are made of.
- Terminal: a node program's transcript no longer fills with blank rows when the program clears
  the screen. A line that was entirely escape sequences is not a blank line, and `ESC[0J`
  (erase below — how `readline.clearScreenDown`, and therefore vite and every watcher, clears)
  now clears the scrollback. `npx vite` prints its version and URL and nothing else.
- Node layer: a forked child's `env` accepts the values node accepts. Booleans and numbers are
  coerced to strings as node coerces them (`PROD: false` arrives as `"false"`); one non-string
  value used to make the whole environment fail to convert, and the child received none of it.
- Node layer: a forked child's script path is normalised, so a path that walks back through a
  file — `…/dist/index.js/../entry/process.js`, how a worker pool names its entry — resolves.
  A script that cannot be read now fails with `Cannot find module` and exit 1 instead of being
  run AS the program, which produced a child that did nothing and never exited.
- Node layer: a forked child exits when nothing is listening. The IPC channel held its event
  loop open by existing; in node that hold belongs to a `'message'` listener.
- Node layer: a cyclic ESM import no longer throws. Real ESM reads a binding where it is used,
  by which time the cycle has closed; destructuring it at import time read it mid-evaluation, in
  TDZ — which is what execa's `send.js` ↔ `strict.js` pair hit. Imported names are read through
  a helper that falls back to reading at the call, and only where the alternative was a throw.
- Node layer: `export const { a, b: c } = …` and `export const [x] = …` are transpiled. The
  declaration had no pass at all, so signal-exit (under execa) failed to parse.
- Node layer: `SharedArrayBuffer.prototype` is `ArrayBuffer.prototype`, so the `byteLength`
  accessor is where jsdom and mongoose look for it.
- Node layer: `child_process` IPC honours node's two serialisation modes — `json` (the default,
  which drops functions and flattens a Map) and `advanced` (the structured clone algorithm).
  A sweep had moved this site onto the clone codec, making the engine stricter than node: a
  message carrying a callback threw where node quietly drops the property. `worker_threads` is
  exempt, having no json mode — a Map posted back from a worker stays a Map.
- Node layer: `MessagePort` no longer exposes its internals as own enumerable properties. Node's
  has none, and real code spreads a port (`{ ...message, source: 'port' }`), which dragged in the
  peer pointer and made the message cyclic.
- msh: `./tool.mjs`, `./app.ts` and the other JavaScript extensions typed at the prompt run on
  the node engine. Only `.js` was routed there, so the rest were handed to the shell, which
  tried to run JavaScript as `sh`.
- Node layer: a syntax error in the entry script is reported. It printed nothing and exited 0
  — a program that neither runs nor says so — and now prints the file and the SyntaxError and
  exits 1, as node does.
- Node layer: `util.debuglog`, `util.debug` and `crypto.generateKey` work when destructured.
  They reached through `this` for a sibling function, which is undefined the moment the
  function travels alone — and `const { debuglog } = require('node:util')` is avvio's first
  line, so **fastify could not boot**. The same shape as `process.hrtime`, which eslint
  destructures; a gate now calls 29 core functions unbound and statically flags any core module
  function that reaches through `this` before nesting a function of its own.
- Node layer: `require`ing a `.node` file fails with `ERR_DLOPEN_FAILED` and the reason
  `process.dlopen` already gave — a compiled addon and a platform that will not map new
  executable pages — naming the file. It used to report `MODULE_NOT_FOUND`, which describes a
  broken install rather than a wall, and no reinstall can fix a wall. `require.resolve` finds
  the file, as node's does; all six outcomes now carry the code real node carries.
- Node layer: `__esModule` is non-enumerable. Node's module namespace has no such key, so it
  was appearing in `Object.keys(ns)` and in anything that spreads or walks a module's exports.
- Node layer: the ESM→CJS transpiler no longer rewrites JavaScript that lives inside STRINGS. A
  bundle ships code as data — vite serves the browser's `import.meta.hot` and a worker shim
  beginning `export default function WorkerWrapper` as template literals — and the textual
  rewrites edited those too. Every rewrite now runs through a scanner that tracks strings,
  template literals with `${}` nesting, both comment forms and regex literals; statement
  patterns match a mask of that scan and apply to the original at the same offsets.
- Node layer: `export async function*` and `export function*` kept their `export` keyword (the
  pattern had no place for the `*`), and a statement pattern's leading `\s*` reached back across
  the newline, gluing `module.exports.default =` onto the previous line's `}`. Both were
  invisible while every dual package resolved to its CommonJS half.
- Node layer: resolving a relative reference against a `file:` base dropped the empty authority
  — `new URL('../p.json', 'file:///a/b/c.js')` gave `file:/a/p.json`. The `//` marks an
  authority, not a host; `href` had been fixed for this at one site and the resolution path
  still keyed off `hostname`.
- Node layer: `Cannot parse '<file>'` now carries JSC's own syntax error and line number. The
  message was the only thing that could say where in a 2 MB bundle the transpiler went wrong,
  and it was being swallowed by the context's fatal-error handler.

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
