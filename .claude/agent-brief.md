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

## CORRECTION — the gateway's transport is stdio, and the network face is WebSocket

`HermesGateway` speaks newline-delimited JSON over **TCP**, and it is proven
against a stub — streamed events, split writes, advancing ids, refused
addresses, and a real conversation rendered in the container. But `tui_gateway`
does not listen on TCP. `tui_gateway/server.py` drives the agent over a child
process's **stdin/stdout** (`proc.stdin.write(json.dumps({"id", "command"}) +
"\n")`), and its network face is the **WebSocket** layer in `tui_gateway/ws.py`,
served by uvicorn, which is what the dashboard attaches to.

So the line protocol is right and the socket is wrong. Two ways to close it, and
the first is the honest one:

1. **Speak the WebSocket layer.** Hermes already serves it for a non-terminal
   front-end, which is the same argument that makes the Telegram bot work.
   `HermesGateway` keeps its framing and its `Event`; only the transport under
   `connect`/`write`/`receive` changes. Read `tui_gateway/ws.py` for the URL
   shape and whatever handshake it expects.
2. A stdio-to-TCP bridge on the host — fewer changes here, but it asks the user
   to run a shim, which is a worse product than talking to what Hermes serves.

The TCP path stays useful either way: it is what the stub gate exercises, and it
is the fallback for anyone who does run a bridge.

## Superseded — the original gateway client design

The container asks for `HERMES_GATEWAY host:port` and then refuses to use it,
because Hermes is marked blocked for having no local install. That is
incoherent: the address is exactly what makes it NOT blocked. `blocked` should
be conditional — no gateway configured means unusable, a configured gateway
means usable — and `send()` should take a different path entirely for it:

- Claude Code: run the CLI locally, as now.
- Hermes: open a socket to `HERMES_GATEWAY`, write `{"id": n, "command": …}` as
  one line, read event lines back, map them onto messages. No install, no
  launch, no terminal. `tui_gateway/server.py` (`dispatch`, `write_json`) is the
  protocol and `hermes_cli/telegram_managed_bot.py` is a working front-end to
  copy the shape from.

Verify it against a STUB that speaks the protocol before asking the user to run
the real thing — a fake gateway on the Mac proves the client without needing
their Python environment or their keys.

## Where it actually stands (measured, not assumed)

The container renders and the picker works. Neither agent runs. Sending "Hello"
with Hermes selected produced, on the user's own device:

    Hello
    pip install hermes-agent          ← the install note
    (no output)                       ← the agent message

That was three separate faults, and all three are now found and fixed:

- **There is no pip.** `pkg install python` lands CPython 3.14.6 and that build
  answers `python -m pip --version` with "No module named pip" and `ensurepip`
  the same. No Python package can be installed on this device. Hermes is
  therefore a network client or nothing.
- **The reporting was lying.** `run` waited only on `isRunning`, which a
  full-screen program leaves false, and counted an error line as success. Both
  fixed; it now shows the command's own words.
- **Scoped bins were never registered.** `npm i -g @anthropic-ai/claude-code`
  said "added 1 packages" and left no `claude`, because the top-level test read
  "no slash after node_modules/" and `@scope/name` has one. Fixed, gated in
  `verify/scopedbin`. `claude` now resolves and starts — and then holds the
  terminal as a program with no output, which is the auth wall below.

## The two things only the user can supply

- **An `ANTHROPIC_API_KEY`** for Claude Code. The field is in the container and
  saves to the keychain. Do not go looking for a key on the machine.
- **A running Hermes gateway** to point at, from `~/Projects/hermes-agent`.

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
