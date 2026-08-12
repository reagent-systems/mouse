# Goal: `npm run dev` works for Node dev servers on iOS

## MET — SvelteKit, on the simulator, curled from the Mac

    VITE v7.3.6  ready in 19343 ms      started once, no restart loop
    curl http://localhost:5173/         HTTP 200, 33105 bytes, the rendered app
    node_modules/.vite/deps             20 dependencies pre-bundled

The watcher was exercised rather than inferred, because silence is also what a
dead watcher produces. Appending a line to `src/routes/+page.svelte` in the
running workspace: ~3s later the curl returned 33133 bytes with the marker in
it, the terminal printed exactly one line —
`[vite] (ssr) page reload src/routes/+page.svelte` — and reverting put it back.
One reload, naming the file that changed. That is the original bug's inverse.

Not a SvelteKit special case, which this brief asks for explicitly. Green on the
same engine: `reactdev` (vite serves .tsx with types erased and JSX compiled),
`hmr` (an edit pushed down a real WebSocket), `firstrun` (`npm create vite`
scaffolds, installs and serves, end to end), `vite`, `npmrun`, `tscwatch`.

Whole suite at the shipping code: **141 assertions passed, 0 failed**, plus the
five harnesses `verify.sh` declares investigations and does not count.

### The fixes, in the order they were found

Each verified on the simulator, each with its evidence in its commit message.

1. **The restart storm** — the project sat at `/`; see the root cause below. A
   program now starts at a named root, so the path it watches has a real parent
   and a real basename.
2. **`import` as a method name** — `obj.import(...)` was read as an import.
3. **ESM named imports were a snapshot, not a live binding**, so a module that
   exports `let x` and assigns it later stayed frozen at `undefined`.
4. **`Request`/`Response` bodies from a Uint8Array** went through `String(body)`
   and arrived as comma-separated character codes, so every SSR response was
   digits (`6328744`).
5. **Svelte's compiler ran half in dev mode** (`e45bb6e`): the live-binding
   rewrite skipped `dev` because `svelte.dev` inside a thrown error's URL read as
   a parameter, and it mis-rewrote shorthand properties written one per line.
6. **lightningcss on wasm, and `file:/x` is the same URL as `file:///x`**
   (`c1e5b16`).
7. **`error.stack` had no `Name: message` header** (`7dfec54`), so every tool
   logging a stack printed frames and no reason.
8. **`listen()` with no host bound IPv4-only `0.0.0.0`** (`213226a`) where node
   binds dual-stack `::`, so a program could not reach its own server by name.
9. **The `/project` alias shadowed a real directory of that name** (`dbd5d2d`).

## Still open

- **Tailwind 4 cannot run here; tailwind 3 can, and does.** Version 3 has no
  native half — scanner and compiler are both JavaScript — and
  `verify/tailwind` pins it: content scanning, plain utilities, a `hover:`
  variant, a `md:` breakpoint reaching `@media`, an arbitrary `w-[37px]`, and an
  unused class correctly absent. A user who wants tailwind on a phone today
  wants 3.

  Version 4 is a platform wall, not our bug. `@tailwindcss/oxide`'s wasi build
  declares SHARED memory and JSC answers `WebAssembly.Module doesn't parse at
  byte 398: shared memory is not enabled`. Measured, so nobody re-derives it:
  `new WebAssembly.Memory({shared: true})` succeeds, but a module whose memory
  section carries the shared flag does not parse. The gate is
  `JSC::Options::useSharedArrayBuffer`, RESTRICTED in Apple's build —
  `JSC_useSharedArrayBuffer=true` is accepted as a name (a bogus name beside it
  is rejected, so the parse happened) and `JSC_dumpOptions=1` still prints
  `useSharedArrayBuffer=false (default: false)`. This bounds every napi-rs wasi
  binding built with threads. `tailwindcss()` is therefore kept out of
  `local__test-2`'s `vite.config.ts`, and the project runs.

- **An error the ENGINE throws still has no header when read through `.stack`.**
  JSC materialises `stack` during construction, on its own errors as much as
  ours, and no hook sees that moment. Errors JavaScript constructs are covered;
  console and util.inspect rebuild the header for the rest.

## The target, concretely

In the simulator workspace `local__test-2` (a SvelteKit project created by
`npx sv create`), `npm run dev` must start **once** — no restart loop; not print
`Failed to run dependency scan`; print its URL; and answer
`curl http://localhost:<port>/` **from the Mac** with the app's HTML.

The fix belongs in the ENGINE (`swift/`). Do not "fix" it by editing the user's
project or `node_modules`. Temporary instrumentation of `node_modules` is
allowed for diagnosis and MUST be reverted before the iteration ends. It must be
general — React/Vite and any other node dev server.

## Root cause of the storm — measured, do not re-derive

A project rooted at `/` breaks file watching, spectacularly. chokidar records a
directory under its parent: `_getWatchedDir(dirname(dir)).add(basename(dir))`.
For `dir === "/"`, POSIX gives dirname `/` and basename `""` — node agrees, our
path module is right — so it files an EMPTY-NAMED child inside the root's own
record. The next `_handleRead('/')` holds the real entries and never contains
`""`, so the diff removes it, `_remove('/', '')` resolves back to the root, and
the whole tracked tree is torn down: an `unlink` for every file in the project,
`vite.config.ts` included. Vite restarts, builds a fresh watcher, and does it
again about three seconds later. Captured in one run as:

    REMOVE dir=/ item= currentSize=14 prevN=3

The dependency-scan failure was downstream of that, never a second bug: the scan
is asynchronous, and vite reports `ERR_CLOSED_SERVER` when the plugin container
closes under it — `[plugin: vite:dep-scan] The server is being restarted or
closed. Request is outdated`. Fix the restarts and the scan completes.

No other platform hits this, because no real project lives at the filesystem
root. Gated now by `verify/watchroot`, which drives the real shell because the
fix lives in the launch path; `verify/chokidar` watches a SUBDIRECTORY, which is
why it was green throughout.

**A named root was the only option, and the alternative is proven impossible.**
Making `fs.realpathSync('/')` answer a named alias cannot work: chokidar uses
`dir` — the path as passed in — for dirname/basename bookkeeping, and consults
realpath only for its symlink check. Do not attempt it.

## Ruled out by device probes — do not repeat these

- esbuild core works, and its plugin callbacks over the pipe work.
- `fs.appendFileSync` creates a missing file correctly.
- A raw `fs.watch` on the config plus `fs.watch('.')` reported **zero** events
  while the config was read and while a temp file was written and deleted under
  `node_modules/.vite-temp`. "Reading the config fires an event" is FALSE.
- The event was never a leaked initial-scan `add`; it was `unlink`, and the
  cause is the empty basename above.
- Directory reading was never at fault: `readdir` and `readdirp` both returned
  all 18 entries with working `isFile()`.

## Measuring on the device — read before trusting a number

**The dev server keeps running.** After `npm run dev` the terminal is owned by
the vite PROGRAM: anything typed afterwards goes to vite as KEYSTROKES, not to
msh. Several measurements were contaminated this way, showing output from a
previous run because the new command never started. Confirm the prompt reads
`~ $` (kill with canc TWICE) and that the command echoed before trusting a
result.

**Re-run a red gate before believing it.** Three conclusions in this loop were
wrong the first time and right after a re-run: "the dependency scan is a second
bug"; "devserver is a regression I caused" (a flake — it slept a fixed six
seconds for vite to boot, and now polls); and "event-sequences is pre-existing"
(asserted on a machine where five hung `verify_bin` processes were still
running). A flake and a regression read identically.

## Verification rule

Verify on the booted simulator (iPhone 16 Pro,
`58A6B442-292A-4610-9DE8-500E7E8EBC74`) EVERY iteration: build, install, launch,
drive the terminal, screenshot, and curl the port from the Mac. A green build is
not evidence.

Everything in AGENTS.md applies: gate what you fix, no leftover diagnostics,
docs move with behavior, commit at each boundary with the evidence in the
message.

## Stop condition — met

On the simulator, `npm run dev` in `local__test-2` starts once, prints its URL,
does not print `Failed to run dependency scan`, and a curl from the Mac returns
the app's HTML. Gates green, `swift/` committed. Branch:
`fix/rolldown-wasi-and-causes`.
