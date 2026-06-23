# @mouse-app/relay

WebSocket **PTY relay** for **[Mouse](https://github.com/reagent-systems/mouse)** — the mobile / desktop client for coding with AI in **GitHub Codespaces**. Run this package **inside a Codespace** so Mouse can open terminals and agent sessions over GitHub’s forwarded ports (`*.app.github.dev`).

**Source:** this npm package is developed in the Mouse monorepo under [`relay/`](https://github.com/reagent-systems/mouse/tree/main/relay).

## Requirements

- **Node.js 18+**
- A **GitHub Codespace** (Linux environment with port forwarding to `*.app.github.dev`)

## Install & run

From the Codespace terminal:

```bash
npx @mouse-app/relay
```

Or install globally:

```bash
npm install -g @mouse-app/relay
relay
# or
mouse-relay
```

The server listens on **`0.0.0.0`** so Codespaces port forwarding can reach it. Mouse expects the relay on the forwarded WebSocket URL:

`wss://{codespace-name}-{port}.app.github.dev`

### Auto-start (recommended)

To avoid running `npx` manually after every resume, merge the **devcontainer** snippet from the Mouse app (or copy from [relay auto-start config](https://github.com/reagent-systems/mouse/blob/main/.devcontainer/devcontainer.json)) into your repo’s `.devcontainer/devcontainer.json`.

## Environment

| Variable | Default | Description |
| -------- | ------- | ----------- |
| `MOUSE_RELAY_PORT` | `2222` | HTTP/WebSocket listen port |
| `SHELL` | `/bin/bash` | Shell used for `bash` sessions (login shell: `-l`) |

## Health check

`GET /health` → `200` with JSON `{ "ok": true, ... }` (used by Mouse to see if the relay is up before connecting).

## Protocol (summary)

One WebSocket per client. First message must authenticate; then JSON frames multiplex PTY sessions.

**Authenticate (client → server)**  
`{ "type": "auth", "token": "<github bearer token>" }`

GitHub `/user` is used to validate the token. On success the server sends `{ "type": "auth_ok" }` (or `auth_fail`).

**Sessions**

- `start_session` — `{ "type": "start_session", "id": "…", "command": "bash" | "opencode", "task": "…" }` (optional `task` for opencode)
- `input` / `output` — terminal I/O
- `resize` — PTY size
- `kill_session` — end a session
- `session_exit` — server notifies exit code

**One-shot exec** (powers Mouse's file/git panels)

- `exec` — `{ "type": "exec", "id": "…", "command": "git status --porcelain", "cwd": "…" }` runs a single command (no PTY) and replies with `{ "type": "exec_result", "id": "…", "stdout": "…", "stderr": "…", "code": 0 }`. `cwd` defaults to the repository checked out under `/workspaces`.

Full message shapes are documented in the source header of `mouse-relay.mjs` in the repo.

## Port already in use (`EADDRINUSE`)

If **`listen EADDRINUSE … :2222`** appears, something else (often a **previous relay** in another terminal) is bound to that port.

See what is bound, then stop it:

```bash
ss -tlnp | grep ':2222'
# or: lsof -i :2222
```

Then kill that PID, or try:

```bash
pkill -f mouse-relay
fuser -vik 2222/tcp    # -v shows PIDs; use sudo if permission denied
```

The **Mouse** client expects **port 2222** in the Codespace URL (`*-2222.app.github.dev`). Only set **`MOUSE_RELAY_PORT`** to something else if you change **Mouse** to match.

## Security notes

- The relay validates tokens with **GitHub’s API** but does not store them.
- Only run this in environments you trust (e.g. **your Codespace**). Exposing the relay publicly without auth would be unsafe.

## License

See the [Mouse repository](https://github.com/reagent-systems/mouse).
