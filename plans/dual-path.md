# Dual Path: TUI repaint + pkg generalisation

Two work streams, run by two agents simultaneously, each in its own git
worktree. This file is the complete instruction set for both. If the dual
run goes wrong, roll back to the commit that added this file ("Dual Path
PreStart") and run the streams one at a time from these same specs.

The user's goal, verbatim: scripts and packages running in the terminal,
universally — a user installs whatever framework or package they need to
start a fresh project from scratch. Stream A unblocks interactive
scaffolders (`npm create vite` and friends are TUIs). Stream B makes
language runtimes data instead of code.

---

## Rules that bind BOTH agents

**File ownership — the merge depends on this. Do not cross it.**

| Path | Owner |
|---|---|
| `swift/Mouse/TerminalPrograms.swift`, `TerminalSession.swift`, `Terminal.swift`, `TerminalScreen.swift`, `TerminalWidth.swift` | A (TUI) only |
| `swift/Mouse/NodeEngine.swift` | A (TUI) only — B does not need it; mounts already exist |
| `swift/Mouse/Runtimes.swift`, `Shell.swift`, `PackageManager.swift`, `ShellLanguage.swift` | B (pkg) only |
| `STATUS.md`, `system.md`, `README.md`, `AGENTS.md` | NEITHER — the orchestrator writes docs at merge |
| `verify/<new-dirs>` | Each agent creates its own; never edit the other's |
| `verify/verify.sh`, `verify/build-one.sh` | NEITHER edits the grader. B may append a source-set line to `build-one.sh` if a new harness needs it |

If you believe you must touch a file you do not own, STOP and say so in
your report instead of editing it. A clean report beats a dirty merge.

**The simulator belongs to the orchestrator.** Do not install, launch,
terminate, tap, or screenshot the simulator. Do not run `xcrun simctl`.
On-device verification happens after merge, sequentially. Your evidence is
headless harnesses plus a clean build.

**Do not run the full verify suite.** Several harnesses bind ports and
fight concurrent runs. Run only your own harnesses and the directly
adjacent ones named in your spec (`./verify.sh <name> <name>`). The
orchestrator runs the full suite once, after merge.

**Do not run xcodebuild concurrently with harnesses** — it has produced a
false suite failure before. Build, then verify, or the reverse.

**Builds:** use a private derived-data path so parallel builds don't
collide, e.g. `-derivedDataPath "$TMPDIR/dd-tui"` / `"$TMPDIR/dd-pkg"`.
Build check:
`xcodebuild -project swift/Mouse.xcodeproj -scheme Mouse -destination
'generic/platform=iOS Simulator' build`.
If you add/remove/rename source files: `cd swift && xcodegen generate`
first.

**Harness style (traps that have already cost iterations):**
- The grader reads the LAST top-level line containing a verdict word and
  judges only the text before the em dash. Passing verdicts must not
  contain "fail", "differ", "mismatch" anywhere in that segment.
- A harness must create every fixture it needs on first run (install
  packages through PackageManager, generate keys, write scripts).
  A harness that assumes files someone left behind passes for the wrong
  reason — this suite was broken for exactly that reason once.
- If your harness spins `RunLoop.current` to pump the engine, do NOT
  `await` on the main thread before the pump — an await resumes on a
  cooperative thread whose `current` run loop is nobody's. Block on a
  semaphore around a detached task instead (see `verify/inkwide/main.swift`
  for the worked example and comment).
- Real node segfaults nondeterministically on large wasm modules —
  do not use it as the reference for big-module behaviour; assert the
  runtime's own documented behaviour (see `verify/python/main.swift`).

**Commits:** commit in your worktree at each boundary with evidence in the
message, ending with the standard co-author line. Do not push. Report your
branch name when done.

**Awareness:** the other stream's scope is described below. You share
`AGENTS.md` law: no demo scaffolding, no leftover diagnostics, refusals
name true reasons. Your changes will be merged together; keep diffs tight.

---

## Stream A — TUI repaint and input

### The problem, as observed on the phone

claude-code 1.0.128 (`node node_modules/@anthropic-ai/claude-code/cli.js`)
drew its `✳ Welcome to Claude Code` box at the BOTTOM of the container, in
the scrollback area, small, and a subsequent keystroke produced no visible
change. Screenshot exists at 23:58 on 2026-07-31. The `^C` chip (added in
dcb0ac1) did return the prompt afterward, so the program/interrupt path
works.

### Hypothesis — to be CONFIRMED before any fix, not assumed

The terminal renders either scrollback (transcript) or the phase-T
character grid, switching on `program.rendersScreen`. Ink-style TUIs do
NOT enter the alternate screen; they repaint inline by cursor-up +
redraw. If grid engagement is keyed on alt-screen (or on something ink
never does), ink output lands in the scrollback as appended lines: wrong
position, stacking frames, cursor movement meaningless, and possibly
input never routed. Find the ACTUAL engagement rule in
`TerminalPrograms.swift` / `TerminalSession.swift` / `Terminal.swift`
first, and write down what it is before changing it.

### Known context

- `NodeProgram.onlcr` exists and is gated (`verify/tty` case 15 renders a
  captured claude-code frame aligned on the grid vs pyte). So the GRID
  handles these frames correctly when fed; the question is engagement and
  routing, not the parser.
- DSR/DA/DECRQM query replies round-trip (verify/tty case 16).
- Keyboard encoding (arrows, DECCKM) lives in `TerminalKey`;
  `sendKey`/`sendSpecialKey` route only when `program != nil`.
- ink checks `process.stdout.isTTY` and columns/rows; the node engine's
  tty layer answers these — if diagnosis leads there, that file is yours.

### The work

1. **Diagnose.** Run an inline-repaint program headlessly through
   `TerminalSession`/`NodeProgram` and record where its output actually
   goes and what `rendersScreen` reports. Do not fix before this is
   written down.
2. **Fix engagement** so a program that repaints inline (cursor-up, CR,
   erase-line — ink's idiom) gets the grid, while `echo`-style one-shot
   commands still go to the scrollback. State the rule you chose in a
   comment: it is architecture.
3. **Fix input routing** if diagnosis shows keys don't reach the program
   or arrive mis-encoded while on the grid.
4. **Exit behaviour:** when the program ends, the terminal returns to the
   scrollback with the prompt usable (the `^C` path already proves part
   of this).

### Verification (headless — the orchestrator does the simulator half)

New harness `verify/tuinline`:
- A node program that draws N lines, then repaints one of them via
  cursor-up without alt-screen (ink's core move), driven through the real
  `TerminalSession`.
- Assert: grid engaged; after repaint the grid holds the NEW text at the
  SAME row; total row usage did not grow per frame (no stacking).
- Assert: a keystroke sent mid-run reaches the program (have the program
  echo a marker on input).
- Control: `echo hi` still lands in the scrollback, grid NOT engaged.
Also run: `./verify.sh tty altscreen inkwide widetui tuinline` — all green.

### Done means

Diagnosis written, rule fixed and commented, harness green alongside the
four neighbours, app builds, committed on your branch. The orchestrator
then proves `npm create vite`'s prompts on the simulator.

---

## Stream B — pkg: languages as data

### The problem

`RuntimeCatalog.all = [python]` is a Swift array; `pythonCmd` hardcodes
Python's env and launch; `python`/`python3` are literal `case` labels in
msh dispatch. Adding a language today means Swift edits and an app
release. The acceptance test for this stream: **after the refactor,
adding language N+1 requires zero Swift changes.**

### The work

1. **Descriptor.** Extend the catalog entry to carry everything the
   launcher needs as data: `archive` format (`zip` | `tar.gz`), `wasm`
   path within the archive, `commands` (e.g. `["python", "python3"]`),
   `env` map with `{root}` expanding to the mount path, optional
   `argPathRewrite` behaviour (Python rewrites bare script paths to
   absolute virtual paths — generalise exactly what `pythonCmd` does
   today, no more).
2. **Generic launcher.** One code path builds the WASI bootstrap from a
   descriptor. `pythonCmd`'s body becomes data in Python's entry. Keep
   the bootstrap identical in behaviour for Python — `verify/python` and
   `verify/pkgpython` must stay green unmodified. Those two harnesses are
   the regression net for this refactor; do not edit them to make them
   pass.
3. **Dynamic dispatch.** Before msh's "command not found", check installed
   runtimes' declared `commands`. The literal `python` cases collapse into
   this. `pkg` stays a builtin.
4. **tar.gz.** `RuntimeStore.install` currently assumes zip. Dispatch on
   the descriptor's `archive` using the existing `TarGz` machinery npm
   tarballs already use. Keep the path-escape refusal for both formats.
5. **Second language, as data only.** Ruby has an official artifact:
   `ruby.wasm` release `2.9.4`, asset
   `ruby-3.4-wasm32-unknown-wasip1-full.tar.gz` (~25 MB) — single-file
   interpreter + stdlib, wasip1, the shape our WASI runs. Lua is
   acceptable instead if a trustworthy wasi build exists; do not build
   one from source in this stream. Record the sha256 you fetched and the
   exact URL in the entry.
   - Expect layout discovery: find where the stdlib lives in the archive
     and what env the interpreter needs (`RUBYLIB` or equivalent) by
     probing headlessly. If the descriptor needs a field this forces,
     add the minimal field and say so in the commit.
6. **Refusals stay honest.** An uninstalled runtime's command must still
   answer "not installed — `pkg install <name>`" via dynamic dispatch,
   not "command not found".

### Verification

- `verify/python` and `verify/pkgpython` pass UNMODIFIED (the refactor
  proof).
- New harness `verify/pkgruby` (or `pkglua`), modelled on `pkgpython`:
  install through msh, run a script file, run `-c`/`-e` equivalent, read
  a project file, non-zero exit surfaces, remove works. Assert the
  interpreter's own behaviour; do not diff real node on a 25 MB module.
- A grep-level assertion in the harness or its comment: the language's
  name appears in ZERO `.swift` files (`grep -ri ruby swift/Mouse/` finds
  nothing) — that is the "data only" proof.
- Also run: `./verify.sh python pkgpython pkgruby npmalias pkg` — green.

### Done means

Python running through the generic path with its harnesses untouched and
green; second language installed and running as pure data; dispatch
dynamic; build clean; committed on your branch. The orchestrator then
proves `pkg install ruby` + `ruby hello.rb` on the simulator.

### Explicitly out of scope for B

Remote index / `pkg install <url>` (decision pending with the user),
SQL, C/C++, `$PATH`/exec-bits/jobs, and anything in Stream A's files.

---

## Orchestrator protocol (after both report)

1. Merge A, then B, into `vs-code-features`; resolve nothing silently —
   any conflict outside `project.pbxproj` means an ownership breach worth
   reading closely.
2. `cd swift && xcodegen generate`; full build.
3. Full `verify/verify.sh` — the bar is the current baseline: 135+ pass,
   0 fail, 0 build-broken (plus the two streams' new harnesses).
4. Simulator, sequentially: background the app with HOME first (never
   terminate-first — it wipes the user's layout), then per stream:
   - A: `npm create vite` (or equivalent ink scaffolder) completes its
     prompts; screenshot.
   - B: `pkg install ruby`; `ruby hello.rb` prints; screenshot.
5. Docs: STATUS.md and system.md updated by the orchestrator only.
6. Loop STOP condition (the completion promise): both simulator proofs
   captured, full suite green, both streams merged and committed.
