---
active: true
iteration: 7
session_id: f1ee49c6-93f4-4a63-9c10-51994e47370d
max_iterations: 200
completion_promise: "Python, a node dev server, and an agent CLI all run from the app's terminal, each verified on the simulator"
started_at: "2026-08-01T21:45:00Z"
---

Make the terminal RUN real work. Not highlighting — execution. The loop ends when all three of these are true ON THE SIMULATOR, each with a screenshot: (a) `python hello.py` prints; (b) a node dev server runs and answers a request; (c) an agent CLI — claude-code, opencode or Hermes — starts and renders its UI in the terminal.

Order: (1) DONE, and it was never a bug — `npm install left-pad` and `node -e` both print correctly on the phone (22:35, build of 41d7fe8). The "lost output" was a screenshot taken before an async network install had returned; `verify/termsays` had already proved the session keeps the line. (2) DONE — `npx n8n` runs on the phone; three walls found and fixed (stale `process.version`, missing `node -p`, missing `util.inspect.defaultOptions` and the custom hook behind it). (4) DONE headlessly — `pkg install python` runs CPython 3.14.6 from the official wasm32-wasi build (`verify/python`, `verify/pkgpython`); it did NOT need the process layer first, only a mount table, and it found two WASI bugs nothing smaller ever would: the standard streams reported as directories, and `fd_readdir` truncating a listing in a way that means "directory ended". (4b) DONE — `pkg install python`, `python -c` and `python hello.py` all verified ON THE SIMULATOR with screenshots (23:48, commit a80806c). STILL TO DO: (3) agent CLIs on the phone; (b) a node dev server answering a request on the simulator; (5) Lua, Ruby, SQL; (6) C/C++ via clang-wasm; the process half of E (`$PATH`, exec bits, `&`/`jobs`/`kill` — the lexer's `&` refusal now states the true reason); phase C, the Preview container; and persisting the ring layout, which is lost on every relaunch and costs a full re-navigation per test build. Phase C (the Preview container) and the rest of phase E are in scope for this loop — the user asked for them by name.

PARKED, and not by choice: Rust, Swift, Go, C#, Kotlin and Java cannot be COMPILED on device — swiftc and rustc are LLVM-sized, the iOS SDK is ~10 GB and not redistributable, and iOS will not execute unsigned machine code. Their real path is compile.md Phase 7 (the CI bridge) plus xcode.md (on-device signing and install), which is a different phase from this one. Do not start it inside this loop; say so plainly if it comes up.

VERIFICATION IS NOT OPTIONAL AND NOT HEADLESS-ONLY. Headless harnesses while working, AND before every boundary commit: build for the simulator, install, launch, drive the real UI, screenshot, read it. A harness passing is not evidence the app works — a whole phase was verified headlessly and never once run on a phone. If the simulator disagrees with a harness, the simulator is right.

DRIVING THE UI: screenshot after every launch and after every tap that changes state. Never tap from memorised coordinates, and never tap immediately after launch — that has already created junk rings and cost an iteration.

Everything in AGENTS.md still applies: no demo scaffolding, no leftover diagnostics, docs move with behaviour, refusals name a true and specific reason, and a refusal that outlives its reason is a false statement — delete it. Commit at each boundary with the evidence in the message.
