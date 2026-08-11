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

## ROOT CAUSE FOUND (iteration 4) — the project sits at `/`, and chokidar cannot cope

Instrumenting the INLINED chokidar's removal diff produced the answer in one run:

    REMOVE dir=/ item= currentSize=14 prevN=3

The item being removed is the EMPTY STRING, and `currentSize=14` proves the directory read is
healthy. The mechanism:

- Our workspace is mounted so the project root is literally `/`.
- chokidar's `_handleDir` does `_getWatchedDir(dirname(dir)).add(basename(dir))`.
- For `dir === '/'`, POSIX says `dirname('/') === '/'` and `basename('/') === ''` (node agrees;
  our path module is CORRECT here — this is not a path bug).
- So chokidar adds an empty-string child INTO THE ROOT'S OWN watched-dir record.
- On the next `_handleRead('/')`, `current` holds the real 14-15 entries and never contains `''`,
  so the diff removes `''` -> `_remove('/', '')` -> that resolves back to the root itself and
  tears down the whole tracked tree, emitting `unlink` for EVERY file, including vite.config.ts.
- vite sees the config unlinked -> restarts -> new watcher -> same thing ~3s later. The loop.

On a real machine a project is never at `/`, so `dirname` returns a real parent and `basename` a
real name; this edge case never fires. It is our virtual-filesystem layout that triggers it, so
the fix belongs in swift/ and is general — it will fix watching for React/Vite/anything, and HMR
along with it.

### IMPLEMENTATION SCOPE, measured in iteration 5

The trigger is one line: `Shell.swift:1474` (and `:1485`) launch node with `cwd: "/" + cwd`, so at
the workspace root a program's cwd is exactly `/`. vite takes that as `root`, chokidar watches
`/`, and the empty-basename bug fires.

Changing the project's virtual root is NOT a one-line change: the whole engine is `/`-rooted —
the module resolver and loader emit `mouse:///…` paths, stack traces and the source-context
header print them, the Viewer's openFile hook receives them, and msh clamps paths to the root.
Any rename shows up in all of those, which is why this needs a deliberate choice rather than a
quick edit. THE OWNER SHOULD PICK, because option A changes what users see.

  A. Root the workspace at a NAMED virtual path (e.g. `/project`) instead of `/`.
     Correct and general — real projects are never at `/`, which is exactly why no other
     platform hits this. Cost: user-visible paths change everywhere (prompt, traces, Viewer),
     and every gate that asserts a `/`-rooted path needs updating.
  B. Keep `/` as the workspace root, but make the path chokidar WATCHES have a real basename —
     e.g. have `fs.realpathSync('/')` answer a named alias that also resolves, since chokidar
     calls realpath on its watch target and uses the result for its bookkeeping.
     Much smaller blast radius, but two names for one directory can desynchronise anything that
     compares paths by string (vite computes root-relative paths constantly), so it must be
     proven against the real dev server, not just a unit gate.

**CORRECTION (iteration 6): OPTION B IS IMPOSSIBLE. Do not attempt it.** It assumed chokidar
uses the realpath of the watch target for its bookkeeping. It does not. In vite's inlined
chokidar, `_handleDir` reads:

    const parentDir$1 = this.fsw._getWatchedDir(sysPath$2.dirname(dir));   // 13263
    const tracked     = parentDir$1.has(sysPath$2.basename(dir));          // 13264
    parentDir$1.add(sysPath$2.basename(dir));                              // 13268

`dir` — the path as passed in — drives dirname/basename; `realpath` is only consulted for the
`_symlinkPaths` check further down. So changing what realpath answers cannot remove the
empty-basename child. OPTION A IS THE ONLY FIX.

### Option A, implementation plan (verified call sites)

1. `swift/Mouse/Shell.swift:1474` and `:1485` — both launch node with `cwd: "/" + cwd`. Change to
   a NAMED root, e.g. `/project`, joined with msh's relative cwd:
   `"/project" + (cwd.isEmpty ? "" : "/" + cwd)`.
2. `swift/Mouse/NodeEngine.swift:2492 realURL(_:)` is the single virtual->real resolver. It
   already walks `mounts` with prefix matching, so the named root can be added as an ALIAS that
   resolves to the same workspace URL as `/`. Both `/project/src/a.js` and `/src/a.js` then work,
   which keeps existing behaviour intact while giving vite a root with a real basename.
3. Because vite derives every path from its own `root`, it will consistently see `/project/...`
   and never mix the two spellings. The thing to watch for in verification is anything that
   hands a program a `/`-rooted path AFTER startup (the Viewer's openFile hook, msh's own path
   clamping) — those still speak `/`, which is fine as long as nothing string-compares the two.
4. Stack traces will read `mouse:///project/...`. Cosmetic, but docs and any gate pinning
   `mouse:///` paths must move with it.

### The gate this needs, whichever option wins
A harness that watches a tree whose root is the VIRTUAL ROOT with chokidar, changes nothing, and
asserts that NO `unlink` is emitted within a few seconds. That is the exact shape of the bug and
nothing in verify/ covers it today (verify/chokidar watches a subdirectory, which is why it has
always passed).

### The original two options (superseded by the scope note above)
1. **Give the workspace a non-root virtual path** (e.g. cwd `/project`, or a mount alias) so the
   watched root has a real basename. The engine already has a `mounts` concept
   (`NodeEngine(root:mounts:)`, `normalizeMountPrefix`, NodeEngine.swift ~193-201, 2476-2494) and
   programs are launched with an explicit `cwd` (TerminalPrograms.swift ~341/397/441). Smallest
   version: keep `/` working as it does today AND expose the same tree at a named path, then
   launch node programs with that as cwd so tools resolve `root` to the named path.
   Risk: user-visible paths change (msh prompt, Viewer, error traces) — check before committing.
2. **Make the root behave like a named directory to watchers only** — riskier and more magical;
   prefer 1 unless 1 proves invasive.

Whichever is chosen: gate it. A harness that watches a directory tree whose root is `/` and
asserts that NO unlink is emitted when nothing is deleted would have caught this, and there is
currently no such gate (verify/chokidar passes because it does not watch the virtual root).

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
