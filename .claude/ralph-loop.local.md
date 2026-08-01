---
active: true
iteration: 1
session_id: f1ee49c6-93f4-4a63-9c10-51994e47370d
max_iterations: 100
completion_promise: "TUI programs repaint in place with working input, and a second language installed purely as data runs — both proven on the simulator with screenshots, full suite green, both streams merged"
started_at: "2026-08-01T02:30:00Z"
---

Dual Path: two agents run simultaneously from the specs in
plans/dual-path.md — Stream A (TUI repaint + input) and Stream B (pkg:
languages as data). Each works in its own git worktree under the file
ownership table in that spec. The orchestrator (this session) launches
them, answers their questions, merges per the protocol at the bottom of
the spec, runs the FULL suite once after merge, and does ALL simulator
verification sequentially (agents never touch the simulator).

THE LOOP ENDS when the completion promise is true: (A) an inline-repaint
TUI (ink-style scaffolder) repaints in place and takes input on the
simulator, screenshotted; (B) `pkg install ruby` (or lua) — added with
zero Swift changes — installs and `ruby hello.rb` runs on the simulator,
screenshotted; the full verify suite is green (135+ pass, 0 fail); and
both streams are merged and committed on vs-code-features.

Rollback point: the commit marked "Dual Path PreStart". If the dual run
tangles, reset to it and run the two specs one at a time.

Standing rules: never terminate the app before backgrounding it (HOME
first — terminate-first wipes the user's ring layout); simulator work is
sequential and orchestrator-only; scope is ONLY what the two specs name —
no side quests; everything in AGENTS.md applies; commit at boundaries
with evidence.
