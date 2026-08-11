# Goal: `npm run dev` works for Node dev servers on iOS

The loop prompt points here. Read this file every iteration.

## The target, concretely

In the simulator workspace `local__test-2` (a SvelteKit project created by `npx sv create`),
`npm run dev` must:

1. start **once** — no restart loop,
2. not print `Failed to run dependency scan`,
3. print its URL, and
4. answer `curl http://localhost:<port>/` **from the Mac** with the app's HTML —
   not a 500, not a refused connection.

The fix belongs in the ENGINE (`swift/`). Do not "fix" it by editing the user's project
or `node_modules`. Temporary instrumentation of `node_modules` is allowed for diagnosis
and MUST be reverted before the iteration ends.

It must be general — React/Vite and any other node dev server, not a SvelteKit special case.

## Root cause chain — measured, do not re-derive

1. Vite prints `vite.config.ts changed, restarting server...` every ~2-3 seconds, forever.
   The config's **mtime is constant** across restarts — the file genuinely never changes.
2. Each restart **aborts the in-flight esbuild dependency scan**. The captured scan error is
   `[ERROR] The server is being restarted or closed. Request is outdated`,
   `code: ERR_CLOSED_SERVER`, plugin `vite:dep-scan`, on @sveltejs/kit runtime files.
   So "dependencies are not found" is a CONSEQUENCE of the restart loop, not a second bug.
   Fix the loop and the scan should complete.
3. Vite's trigger is `handleHMRUpdate` in `node_modules/vite/dist/node/chunks/config.js`:
   it restarts when the changed file equals `config.configFile`, is in
   `config.configFileDependencies`, or is an env file. The printed name is exactly
   `vite.config.ts`, so the file it saw IS the config path.

## Already ruled out by device probes — do not repeat

- esbuild core works: bundled a module, 38 bytes out.
- esbuild **plugin callbacks** over the pipe work (onResolve/onLoad): `PLUGIN OK bytes=61`.
- `fs.appendFileSync` creates a missing file correctly.
- A raw `fs.watch` on the config plus `fs.watch('.')` reported **zero** events while the
  config was READ and while a temp file was written and deleted under
  `node_modules/.vite-temp`. The naive "reading the config fires an event" theory is FALSE.
- The socket leak is already fixed (3607 leaked listeners, now bounded) — commit b1133b6.

## ITERATION 1 FINDINGS — the theory in "Chase this first" below is now DEAD

Two measurements, both on the simulator with the real project:

1. `NodeWatch.emit` was instrumented with NSLog (every event, path + kind). During a FULL vite
   restart loop it logged **ZERO events**. Our fs.watch is not firing at all — spurious events
   are not the problem.
2. A chokidar probe using vite's own options (`chokidar.watch('.', { ignored: [...],
   ignoreInitial: true })`, chokidar 4.0.3, which uses the callback `fs_watch`, not fsevents)
   emitted **only `ready`**. It MISSED a control write of `canary.txt` directly into the watched
   root. So watching is broken in the MISSING-events direction, end to end.

So the restart trigger is NOT the file watcher, and there is a SECOND, separate bug: a new file
in a watched directory produces no event, which also means HMR cannot work.

## ITERATION 3 — THE EVENT IS `unlink`, FOR EVERY FILE IN THE PROJECT

Captured with a deep stack at vite's config-change branch, on a cleanly started server:

    === TYPE=delete FILE=/vite.config.ts
    === TYPE=delete FILE=/static/robots.txt
    === TYPE=delete FILE=/.gitignore
    === TYPE=delete FILE=/.npmrc
    ...

chokidar is telling vite that EVERY FILE IN THE PROJECT WAS DELETED. Nothing was deleted. The
config's unlink is what restarts the server; the restart builds a new watcher, which shortly
declares everything deleted again. That is the loop, and it is an `unlink` storm, not an `add`.
(The iteration-1 guess of a leaked initial-scan `add` was WRONG — it is `delete`.)

Directory reading is NOT the cause. Measured on device in that project:
  - `fs.promises.readdir('.', { withFileTypes: true })` -> n=18, correct names, `isFile()` works.
  - `readdirp('.', { depth: 0, type: 'all' })` -> n=18, every entry listed.
So the reads chokidar depends on are healthy.

### Where the unlink must come from — instrument these two, in vite's INLINED chokidar
IMPORTANT: vite bundles its OWN chokidar inside `node_modules/vite/dist/node/chunks/config.js`
(see the `initialAdd && ignoreInitial` sites there). `node_modules/chokidar` (v4) is a DIFFERENT
copy used by other packages. Instrument the INLINED one — the unlink reaching vite comes from it.

1. `_handleRead`'s directory diff: it builds `current` from a readdirp stream and then does
   `previous.getChildren().filter(item => !current.has(item)).forEach(item => this.fsw._remove(...))`.
   If `current` ends up EMPTY (stream yields nothing, or every entry is filtered out) while
   `previous` holds all the files, every file is removed -> unlink for each. This is the prime
   suspect and matches the symptom exactly.
2. `_handleFile`'s listener catch: `catch { this.fsw._remove(dirname, basename) }` when
   `stat(file)` throws after a watch event.

Decisive next step: add a logging line inside the inlined chokidar's `_remove` that appends
`item` plus `new Error().stack` (with `Error.stackTraceLimit = 60`) to a file using the module's
`fs` binding. That names which of the two paths fires, and the fix follows from it.

## ITERATION 2 — A PROCESS TRAP THAT INVALIDATED MEASUREMENTS, AND A LEAK REFINEMENT

READ THIS BEFORE MEASURING ANYTHING.

1. **The dev server keeps running.** After `npm run dev`, the terminal is owned by the vite
   PROGRAM. Anything typed afterwards goes to vite as KEYSTROKES, not to msh. Several
   iteration-2 measurements were contaminated this way: `who.txt` kept showing output from a
   previous run because the new `npm run dev` never actually started — the text went into the
   running program. ALWAYS confirm the prompt reads `~ $` (kill with canc TWICE) before typing a
   command, and confirm the command echoed on screen before trusting any result.

2. **The listener leak is only HALF fixed.** b1133b6 releases the previous socket when the SAME
   server object re-listens. But vite's restart builds a NEW http.Server each time, binds a new
   port, and never closes the old one (its `createServerCloseFn` skips closing a server it never
   saw emit 'listening'). So every restart still leaks one bound port: observed climbing
   5173 -> 5174 -> ... -> 6087 inside ONE app session. The leak is a SYMPTOM of the restart loop,
   so fixing the loop mostly removes it — but a server that is garbage-collected without close
   should still release its fd, and that is worth fixing on its own.

3. Reading chokidar did not settle the trigger and cost a lot of cycles. Both chokidar copies
   (v4.0.3 in node_modules, v3 inlined in vite's bundle) gate `add` on `initialAdd &&
   ignoreInitial`, and vite passes `ignoreInitial: true` (config.js:16779). The fsevents
   `emitAdd` with its `forceAdd` bypass is NOT our path. So the leak of an `add` is still
   unexplained by reading alone — MEASURE it: instrument chokidar's own `_emit` in node_modules
   to append event+path+initialAdd to a file, with the dev server started cleanly per (1).

### THE TRIGGER IS NOW IDENTIFIED (iteration 1, measured)

A stack capture at vite's config-change branch names the caller:

    handleHMRUpdate  config.js:26028
    onHMRUpdate      config.js:25635
    <anonymous>      config.js:25654   <-- onFileAddUnlink

Line 25654 is the last line of `onFileAddUnlink`, i.e. `onHMRUpdate(isUnlink ? 'delete' :
'create', file)`. So vite is being told the config was **ADDED or UNLINKED**, not changed. The
captured file is `/vite.config.ts`, isConfig=true.

Combine that with the two facts above — our fs.watch emits nothing, and chokidar misses a real
new file — and the coherent theory is:

**chokidar's INITIAL SCAN is leaking 'add' events past `ignoreInitial`.** Every vite restart
builds a NEW chokidar watcher, whose initial scan re-announces `vite.config.ts` as an `add`,
which vite treats as a config change, which restarts the server, which builds another watcher.
That is the whole loop, and it also explains why live changes are missed: only the scan works,
the watch itself delivers nothing.

Likely engine cause to test: chokidar decides when the initial scan is over by counting pending
async operations and then emitting `ready`. If our fs/readdir async completion ordering lets
chokidar flip to ready BEFORE the scan has finished, everything the scan finds afterwards is
emitted as a genuine `add` rather than being suppressed. Look at how our `fs.readdir`/`stat`
callbacks are scheduled relative to `process.nextTick`/microtasks, and at chokidar's
`_emitReady`/`_readyCount` bookkeeping in node_modules/chokidar/esm/handler.js.

Cheap decisive probe for next iteration: chokidar.watch with `ignoreInitial: true` on a
directory, log every `add` WITH a timestamp and log `ready` too. If adds arrive AFTER ready,
the theory is confirmed and the fix is in our async fs scheduling (or in how fs.watch registers).

### Superseded next step
Instrument `handleHMRUpdate` in node_modules/vite/dist/node/chunks/config.js to capture
`new Error().stack` at the moment it decides the config changed, and write it to a file with the
module's own `fs` binding — `fs.writeFileSync('/x.json', ...)` at that site WORKS (proven: it is
how the ERR_CLOSED_SERVER scan error was captured; `require('fs')` there does NOT work). That
stack names the caller and ends the guessing about what triggers the restart.

Then, separately, isolate the missing-events bug: raw `fs.watch('.', cb)` + create a file
directly in that directory, and see whether the callback fires. If it does not, fix directory
watching in NodeWatch.swift and gate it.

### Still-uncommitted instrumentation
`swift/Mouse/NodeWatch.swift` has a TEMP-DIAGNOSTIC NSLog block in `emit(...)`. Remove it before
committing anything.

## Chase this first (SUPERSEDED — kept for the record)

What makes chokidar (riding our `fs.watch`) tell vite the config changed or was added?
Instrument OUR side — `swift/Mouse/NodeWatch.swift` and the `fs.watch` bridge — logging every
event with its path and kind. Do not instrument vite again; that path has been exhausted.

FIRST SUSPECT, found by reading NodeWatch.swift at the end of the last session and NOT yet
tested: the per-file watch registers eventMask `[.write, .rename, .delete, .attrib, .extend]`
(NodeWatch.swift ~line 133), and the handler treats EVERYTHING that is not delete/rename as a
content `change` (~line 150). So a bare NOTE_ATTRIB — an attribute touch, no content change —
is reported to node as `change`. node's own fs.watch does emit on some attribute changes, but
chokidar's atime guard normally absorbs them, and here that guard fails open (see below), so a
single stray NOTE_ATTRIB on the config is enough to restart vite forever. Test whether dropping
`.attrib` (and possibly `.extend`) from the FILE mask, or distinguishing attrib-only events from
writes, stops the loop — then check it does not break verify/chokidar and the fs.watch gates.

Two facts that matter:
- vite creates a **new chokidar watcher on every restart**, and chokidar emits `add` and
  `unlink` as well as `change`; vite treats add/unlink of the config as a restart too.
- On this filesystem **atime == mtime** for the config, which makes chokidar's
  "ignore atime-only events" guard (`at <= mt` -> emit) fail OPEN. So ANY watcher event on
  that file becomes a restart.

## Other known state

- `tailwindcss()` was removed from `local__test-2`'s `vite.config.ts` during debugging to get
  past a lightningcss crash. Either restore it and make it work, or state plainly that it is a
  separate blocker: lightningcss ships only native optionalDependencies with no `wasm32-wasi`,
  and a `lightningcss` -> `lightningcss-wasm` entry in `PackageManager.wasmSubstitutes` is the
  candidate fix.
- Branch: `fix/rolldown-wasi-and-causes`.

## Verification rule

Verify on the booted simulator (iPhone 16 Pro, 58A6B442-292A-4610-9DE8-500E7E8EBC74) EVERY
iteration: build, install, launch, drive the terminal, screenshot, and curl the port from the
Mac. A green build is not evidence.

Everything in AGENTS.md applies: gate what you fix, no leftover diagnostics, docs move with
behavior, commit at each boundary with the evidence in the message.

## Stop condition

On the simulator: `npm run dev` in `local__test-2` starts once, prints its URL, does NOT print
`Failed to run dependency scan`, and a curl from the Mac to that port returns the app's HTML —
with a screenshot and the curl output as evidence. Plus gates green and `swift/` committed.
