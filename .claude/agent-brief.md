# Goal: Hermes Agent and Claude Code both hold a real conversation in the Agent container

## Stop condition

Both agents, in the container, in a chat interface, actually working:

1. Pick **Claude Code** → type a prompt → its answer appears as an agent message.
2. Pick **Hermes Agent** → type a prompt → its answer appears as an agent message.

Both verified on the simulator by driving the app, with a screenshot of each
answering. Not "it installed", not "it printed something" — an answer to a
question, on screen, in the exchange.

Setup is allowed and expected. The current Hermes has **savable profiles**, so
whatever configuration a first run needs (model, API key, backend) is saved and
does not have to be redone every launch. Build that setup into the container
rather than requiring the user to go to the Terminal container.

## Where it actually stands (measured, not assumed)

The container renders and the picker works. Neither agent runs. Sending "Hello"
with Hermes selected produced, on the user's own device:

    Hello
    pip install hermes-agent          ← the install note
    (no output)                       ← the agent message

So `AgentSession.send` ran the install line and got nothing back, then ran the
launch line and got nothing back. Three candidates, none yet checked:

- **Is there a `pip` at all?** Python arrives as CPython wasm32-wasi through
  `pkg install python`. Whether that build has a working `pip`, and whether
  msh resolves it, is unverified. `verify/pkgpython` is the harness that knows.
- **`transcriptTail` may be lying.** It slices after the LAST `.command` line;
  if the run produced no lines, or the command echo is the last line, it
  returns "" and the container prints `(no output)` over a real failure. It
  should distinguish "the program said nothing" from "the program never ran".
- **The launch command is a module path.** `python -m tui_gateway.entry` only
  resolves if the package installed and `python` is on `$PATH` — phase E notes
  `$PATH` is one of the missing pieces.

## What is already known — do not re-derive

- **Hermes is a TUI, and its gateway is the way in.** `tui_gateway/` in
  `~/Projects/hermes-agent` is how Hermes talks to front-ends that are not a
  terminal; the Telegram bot is one of them. `python -m tui_gateway.entry`
  speaks **newline-delimited JSON over stdio** — `{"id": …, "command": …}` in,
  events out — with a WebSocket sidecar for dashboards. Read
  `tui_gateway/server.py` (`dispatch`, `write_json`) and
  `hermes_cli/telegram_managed_bot.py` for how a chat front-end maps onto it.
  **The container does not speak this yet. That is the main missing piece.**
- **Claude Code is pinned at 1.0.128** and must stay pinned: current releases
  ship `bin/claude.exe`, a native binary iOS cannot execute. 1.0.128 is the last
  JS-all-the-way-down line and STATUS.md records it running on the phone.
- **Oh My Pi is out** — Bun CLI with Rust native bindings, no path on iOS.
- Nothing is bundled; each agent installs with its own published command.

## Testing the app — the parts that cost time last run

- **Edge swipe skips onboarding.** Swipe in from the right edge starting around
  x=393 (further in than 4pt, or iOS claims it for Control Center). Do this
  first after every install instead of walking the four lessons.
- A reinstall resets onboarding every time, so expect to do it every iteration.
- The ring cycles GitHub → Files → Viewer → Graph → Terminal → **Agent**: five
  left swipes from GitHub. Horizontal swipe from (340,450) to (60,450).
- The Agent container is **kind 16**, deliberately not 6 (6–15 were retired
  placeholders and live in old snapshots).
- Pick a project first — the Files container's header opens the picker. With no
  project the session refuses and says so.
- Build to a **clean derivedDataPath** and check the product before trusting it:
  a stale `/tmp` product wasted an iteration. `strings` on this binary finds
  nothing — check `Info.plist` keys instead.
- Run `cd swift && xcodegen generate` after adding any file, or the build
  compiles without it and the error is "cannot find X in scope".

## Rules

Fix it in `swift/`. Verify on the simulator every iteration. Commit at each
boundary with the evidence. No demo scaffolding, no leftover diagnostics, docs
move with behaviour.
