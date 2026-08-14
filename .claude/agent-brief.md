# Goal: Hermes Agent and Claude Code both hold a real conversation in the Agent container

## THE ARCHITECTURE (user-set, 2026-08-14): Hermes runs INSIDE Mouse; Mouse is its tool surface

The user's words: "We should think of the mouse app as a scoped tool/skill/mcp
exposed for the hermes agent running inside of mouse." And, before that: "I
never, ever, ever told you to run hermes on my mac. I told you, embed hermes
into the application." Both are binding. No gateway on the Mac, no external
service. The Mac is the build host, nothing else.

Measured facts the design must live with (on-device CPython wasi — 3.12.0 since the zlib swap):

    import ssl        FAILS      import sqlite3    FAILS
    import asyncio    ok         import zipfile    ok
    pip / ensurepip   ABSENT     compiled extensions: wasi CPython cannot
                                 dlopen, so pydantic-core / cryptography /
                                 psutil can never load, ever

Why the MCP framing is not just preference but the ONLY shape that fits: the
agent loop (prompt assembly, tool dispatch, response parsing) is pure Python and
runs fine on wasi. Everything wasi CANNOT do — TLS, processes, the filesystem —
Mouse already does natively: URLSession, msh, the workspace. Hermes is built for
exactly this split: it already abstracts shell backends (local/Docker/SSH) and
speaks MCP to external tools. Mouse becomes one more backend — the phone.

Build order:
1. **Wheel installer** (`pip install <pure-python-wheel>`): PyPI JSON API +
   wheels are zips + `Runtimes.swift` already has the zip reader. Registers a
   site-packages dir the wasm Python imports from. Gate it on installing a real
   pure wheel (e.g. `python-dotenv`) and importing it on device.
2. **The bridge — files per step, not resident stdio.** Measured constraints:
   `wasi.start` is SYNCHRONOUS (the engine's JS thread is blocked while Python
   runs, so nothing async can answer it mid-run) and `fd_read` on stdin answers
   0 bytes — instant EOF. So a resident MCP-over-stdio process is not possible
   on today's engine. What is: ONE PYTHON INVOCATION PER AGENT STEP.
     - Swift writes `bridge/turn.json` (conversation so far + tool results).
     - Python runs the loop step, exits having written `bridge/out.json`:
       either `{"answer": …}` or `{"tool": "llm.complete"|"shell"|"read_file"|…,
       "args": …}`.
     - Swift executes the tool natively — model calls on URLSession (real TLS),
       shell on msh, files on the workspace — appends the result, reruns Python.
   State lives in files between steps, which is also how Hermes already
   persists sessions. Cold-start per step is the price (~1–3s, measured on the
   pip probes); a resident process is an optimization for after the engine
   grows blocking stdin, not a prerequisite.
3. **Hermes profile for Mouse** — MEASURED now, not predicted. `pip install
   hermes-agent==0.19.0` lands EIGHT packages clean, hermes-agent's own 9.9 MB
   pure wheel included, plus openai 3.0.0, httpx, rich, tenacity, fire, dotenv,
   certifi. The closure stops at pyyaml (no pure wheel published). On device:
     - `import openai` dies on `import zlib` — the wasi CPython BUILD ships no
       zlib module. Engine-side gap, not a packaging one: candidates are a
       different CPython wasi artifact that includes zlib, or a shim.
     - The yaml wall FELL: pip substitutes pyyaml with ruamel.yaml (a PyYAML
       fork, pure, already in hermes's pins) plus a `yaml.py` adapter of the
       PyYAML surface. `yaml.safe_load` works on device; hermes's utils.py
       imports through its yaml lines including the SafeDumper subclass.
     - `Path.home()` needed a HOME: Runtimes.json sets `HOME=/`, so agent
       state (`~/.hermes`) lands in the WORKSPACE — per-project agent state,
       which fits Mouse.
     - The "hang" was a CRAWL: -X importtime on the live path showed imports
       streaming at hundreds of ms each. The chain then died at real lines,
       each now answered: `import ssl` (auth.py:26) → a pure ssl shim that
       imports clean and refuses at use; `import webbrowser` → shimmed, there
       is no browser on that side; `concurrent.futures.thread` (the build
       omits it; wasi has no threads) → an INLINE executor via sitecustomize.
     - **`import run_agent` SUCCEEDS on the device.** Warnings only: a plugin
       fails on hashlib.scrypt (this build's hashlib lacks it), and the
       futures patch logs an unknown-location note. Warm import ≈ 4 minutes
       with the pyc cache on ({root}/pycache — PYTHONDONTWRITEBYTECODE is
       gone); cold ≈ 6. Startup cost is now the biggest UX problem, ahead of
       any correctness one.
     - NEXT, designed — RECORD-AND-REPLAY through `AIAgent.chat`. The loop's
       front door is `AIAgent(base_url=…, api_key=…, model=…).chat(message)
       -> str` (run_agent.py:5295), synchronous. Its transport is the openai
       SDK, which cannot import here (pydantic-core), and wasi Python has no
       sockets regardless — so the step driver installs a FAKE `openai`
       module in sys.modules before importing hermes. The fake's
       chat.completions.create():
         1. consults the recorded responses in turn.json, returning them in
            order for calls 1..n-1 (cheap objects with .choices[0].message);
         2. on the first UNRECORDED call, raises a Capture carrying the
            request; the driver writes it as {"tool": "llm.complete"} and
            exits; Mouse executes it on URLSession and reruns with the
            response appended.
       Each step deterministically replays prior turns without network — the
       price is re-running python logic per step, on top of the ≈4 minute
       warm import, which makes the STARTUP COST the thing to solve next:
       likely one resident python invocation per CONVERSATION (not per step)
       once the engine grows blocking stdin, or import pruning.
   Walls known ahead from the dependency list: pydantic-core (via pydantic,
   compiled Rust) and psutil (compiled C). pydantic imports lazily in the
   openai SDK's typed paths — how far the loop gets without it is a
   measurement, not a guess.

Verify each stage on the simulator; a stage that only works with something
running on the Mac fails the user's constraint by definition.

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

## THE ANSWER, from the docs — an OpenAI-compatible endpoint

`/docs/user-guide/features/api-server`. Everything needed to build the client:

- **Start it:** `hermes gateway`. The API server listens on
  **`http://127.0.0.1:8642`** by default — loopback, so a real phone needs the
  host bound wider or reached over the LAN; the SIMULATOR shares the Mac's
  network stack and can use 127.0.0.1 directly.
- **Endpoint:** `POST /v1/chat/completions`, plain OpenAI shape:

      {"model": "hermes-agent",
       "messages": [{"role": "user", "content": "…"}],
       "stream": false}

  answering with `choices[0].message.content`. `"stream": true` gives SSE with
  token chunks plus `hermes.tool.progress` events for tool visibility — the
  streamed narration the orb was built for. `GET /health` is a cheap reachability
  check and `GET /v1/models` names the profile.
- **Auth:** `Authorization: Bearer <API_SERVER_KEY>`, REQUIRED for every
  deployment including the default loopback bind. It cannot be disabled. The key
  is a static value the user sets in the env / profile `.env`.
- **Model name:** defaults to the profile name, or `hermes-agent` for the default
  profile.
- **THE PROFILES the user meant:** multi-profile routing gives each profile its
  own `API_SERVER_KEY` in its own `.env`. So a saved setup here is a (base URL,
  key, model) triple per profile, and the container's settings should hold that
  shape rather than a single string.

This is an ordinary HTTP client — no socket, no framing, no WebSocket. It also
generalises: anything OpenAI-shaped could be another entry in the catalog.

### What to do with `HermesGateway`
Delete the transport. The `Event` type is close to what an SSE stream yields and
may survive; `connect`/`write`/`receive`/`readLine` and the whole TCP path do
not, and neither does `verify/hermesgateway`'s stub. Replacing them with a
URLSession POST is smaller than what is being removed.

## Superseded — the TUI gateway reading

From the official docs (hermes-agent.nousresearch.com/docs/user-guide/messaging),
which should have been read before any of this was built:

- `hermes gateway` is the MESSAGING gateway, and it works by **polling platform
  APIs outbound** — Telegram, Discord, Slack, Signal, Matrix, ntfy and a long
  list of others. It exposes no inbound endpoint.
- **There is no generic or custom channel.** Only named, pre-built platforms.
  So "be a front-end like Telegram is" is not available: Telegram works because
  Hermes has Telegram-specific code and polls Telegram's servers.
- The docs name a separate **"Open WebUI + API Server"** integration. That is
  the supported way a custom client talks to Hermes, and it is almost certainly
  an OpenAI-shaped chat-completions endpoint, which this app can speak trivially.

NEXT: fetch the Open WebUI / API Server integration page for its exact path,
port, payload and auth, then point the container at that. Do not build any more
transport before reading it.

`tui_gateway` was the wrong target twice over: it is stdio with a WebSocket
dashboard face, and it is an internal detail rather than a documented interface.
`HermesGateway`'s framing and `Event` type may still be reusable; its transport
almost certainly is not.

## Superseded twice — the TCP client and the WebSocket plan

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

## CLAUDE CODE: FOUND — it awaits a stream to statsig.anthropic.com

The interrupt ledger answered on its second use:

    interrupted while waiting on: 9 timers, 1× http stream to statsig.anthropic.com

With a key, 1.0.128 initialises statsig (feature flags/telemetry) BEFORE its
first output, and that streaming request never completes on our engine — held
past 127 seconds when URLRequest's default timeout is 60, so delegate events
for that session are not being delivered at all. That is the engine bug to fix
next: reproduce with a bare httpStream to statsig.anthropic.com, find why
didCompleteWithError never fires (large/gzip body? redirect? the response
never draining?), and fix the transport. DISABLE_TELEMETRY /
CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC did not bypass it in 1.0.128.

Where the tool lives: `outstanding` is now a LABELED ledger (`hold(_)` /
`release(_)`), and an interrupted run reports what it was waiting on — named
hosts for http streams. Any future "it just hangs" starts by pressing ^C and
reading the answer.

## Superseded — nine eliminations reached by hand

Everything below is measured, not reasoned:

    dead base_url (http://127.0.0.1:9)     hangs the same — NOT the network target
    net.connect to a refused port          error event in 1ms — sockets fine
    execSync('security …') screenless      throws instantly — no bridge deadlock
    the grid during the hang               empty, onScreen=false — no hidden TUI
    ~/.claude.json onboarding seeded       read correctly (homedir=/), still hangs
    fetch / https.request / streaming / exit / startup / stdin — all previously green

With a key, `claude -p` awaits SOMETHING that never resolves, before its first
write, regardless of endpoint, with every external ruled out. Blind bisection
of a 9.4 MB minified bundle is the wrong tool. The right one is engine-side:
a diagnostic that answers "what is this process waiting ON" — pending timers,
sockets, unresolved host calls — dumped when a run is interrupted. That is a
real engine feature (the streaming probe needed the same question answered),
and it turns this class of bug from guesswork into a lookup.

## Superseded — the single-suspect framing

Not the compound. `export FOO=bar && echo compound-ok` returns in 0s, so `&&`
is fine and the earlier note blaming it was wrong. What actually correlates is
whether a key is set:

    claude -p 'say hi'                       3s   "Invalid API key · Please run /login"
    export ANTHROPIC_API_KEY=sk-ant-invalid
    claude -p 'say hi'                      63s   still running, nothing printed

Two SEPARATE commands on one session — exactly how `AgentSession` does it. With
no key the CLI short-circuits at its own validation and prints. With a key it
gets past validation and makes a real HTTPS call to the API, and THAT is where
it stops. So the suspect is the engine's network path under whatever HTTP client
claude-code 1.0.128 uses, not the shell and not the launch path.

THIS WILL HIT A VALID KEY TOO. A real key also gets past validation into the
same request. Do not tell the user Claude Code is one key away again until this
is understood.

RULED OUT: the network. Both clients reach the real API and come back fast,
with the same request shape the CLI would send:

    fetch          → 0.2s, 401, {"type":"authentication_error", …}
    https.request  → 0.2s, 401, same body

So HTTPS, TLS, DNS and the response path all work under the engine, and whatever
1.0.128 does after passing its own key validation, it is not a plain request to
api.anthropic.com that stalls.

RULED OUT TOO: startup, and stdin. With the key exported, in the same session
that then hangs:

    claude --version   0s   1.0.128 (Claude Code)
    claude --help      0s   full usage text

So the CLI loads, parses, reads its config and prints — none of that waits on a
screen, a prompt or a stdin that never arrives. The hang is specific to `-p`
actually making its request.

Which leaves ONE suspect, and it fits every measurement: `claude -p` asks for a
STREAMING response. A plain request/response works (0.2s, 401, both clients);
what has not been tested is reading a body that arrives in chunks over time.
With no key the CLI never gets that far — it fails validation and prints in 3s.
With a key it opens the stream, and that is exactly where it stops.

TESTED. Reading a chunked body with real delays works exactly right:

    headers at 0.0s status=200
      chunk 1 at 0.0s … chunk 4 at 1.2s
    reader DONE at 1.6s after 4 chunks

and the process exits on its own afterwards. Both forms do:

    text()          exited after 2s
    getReader()     exited after 1s

An earlier note here claimed the process never exited and built a whole theory
on it. That was MY HARNESS lying: the watchdog printed "KILLED" unconditionally
after its sleep, whether or not the process was still alive. The probe had
already finished. Streaming is fine, exiting is fine, and no theory should be
built on a message a test prints regardless of outcome.

SO THE CLAUDE `-p` HANG IS STILL UNEXPLAINED. Eliminated by measurement so far:
the missing key, the launch path (real bug, fixed, not this), the `&&` compound,
the network (fetch and https.request both 0.2s to the real API), startup
(`--version` and `--help` instant WITH a key set), stdin, and now streaming and
event-loop exit.

MEASURED SINCE: it emits NOTHING while hung. On the live path — where a program
writes into the transcript as it goes, so partial output is visible — `claude
--debug -p 'say hi'` produced not one line in 24 seconds. `--debug` should be
noisy from the first moment. So it blocks BEFORE its first write, which rules
out anything that happens after the CLI starts doing visible work, and makes an
early await the suspect: something in its startup path that only runs when a key
is present.

Note the measurement trick, since it took three iterations to find: the
screenless path returns output only when the run COMPLETES, so it shows nothing
about a hang. Run the same command WITHOUT `screenless` and poll
`session.lines` — a program emits into the transcript live.

What has NOT been looked at: what the CLI does between passing validation and
issuing its request. It writes state — `~/.claude`-style config, onboarding
flags, a project trust record. A write to a path the workspace filesystem
handles differently, or a lock/retry around one, would fit: instant without a
key because validation short-circuits first, slow with one because that path is
only reached when the key looks usable. Instrument the engine's fs calls during
the hang and see what it touches last.
(A probe artefact to avoid repeating: a `setTimeout` left running keeps the
engine's loop alive after the work resolves, which looks like a hang and is not.)

## Superseded — the launch path (fixed, and it was real)

The experiment below settled it. Piping anything into the command defeats
`if interactive, stdin.isEmpty` in `runNode`, which sends it down the path that
RETURNS output instead of handing it to `launchProgram` as a screen-owning
program:

    echo '' | claude -p 'say hi'        3s
      Invalid API key · Please run /login

Three seconds, and a real answer from the real CLI. It starts fine on this
engine, reaches its auth check and reports it in words. Every hang was our
launch path: `runInstalledBin` passes `interactive: true`, the bin becomes a
`NodeProgram` that owns the terminal, and a print-mode invocation that wants to
write and exit sits there forever.

THE FIX belongs in how the agent is invoked, not in a pipe trick. `-p` is a
non-interactive invocation and should be dispatched as one. Options, best first:
  1. Let `TerminalSession.run` take a non-interactive flag that `AgentSession`
     sets, threading through to `runNode`'s `interactive:`.
  2. Decide interactivity from the command — a bin invoked with `-p`/`--print`
     is not a screen program. Narrower, and guesses at CLI conventions.
Do NOT ship `echo '' | …` as the mechanism; it works by accident of the
stdin test and would confuse the next reader.

One loose end: `export ANTHROPIC_API_KEY=… && echo '' | claude -p …` hung for
63s where the same pipeline without the `export &&` returned in 3. Something
about the compound puts it back on the interactive path — worth understanding,
because `AgentSession` exports before it launches.

## Superseded — "does not hang for want of a key"

Measured, so nobody spends a key finding out:

    npm install -g @anthropic-ai/claude-code@1.0.128      added 1 packages / bin: claude
    export ANTHROPIC_API_KEY=sk-ant-invalid-for-testing && claude -p 'say hi'
        42s, still running, nothing printed

An invalid key should be REJECTED, quickly and in words. Instead the CLI takes
the terminal as a full-screen program and never comes back, exactly as it did
with no key at all. So authentication is not the wall — something in 1.0.128's
startup does not complete on this engine, and a real key will not change it.

Where to look next: msh runs an installed bin through `runInstalledBin` with
`interactive: true`, which hands it to `context.launchProgram` as a `NodeProgram`
that owns the screen and returns immediately. `-p` is supposed to be the
non-interactive mode, so either the CLI is not taking that path, or it is
waiting on a stdin/TTY that never delivers. Run it NON-interactively — the same
call with `interactive: false` goes through `engine.run` and returns output —
and compare. That one experiment separates "our launch path is wrong" from
"the CLI cannot start here".

## The one thing only the user can supply

- **A running `hermes gateway`** and its profile's `API_SERVER_KEY`. The client,
  the key field and the address field are all built and gated; nothing else is
  needed for Hermes to answer.

Claude Code needs no key from anyone until the hang above is understood.

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
