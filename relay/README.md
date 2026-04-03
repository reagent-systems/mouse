# @mouse-app/relay

WebSocket **PTY relay** for **[Mouse](https://github.com/mouse-app)**. Run it **inside a GitHub Codespace** so the mobile/desktop app can open terminals and agent sessions over forwarded ports.

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

Full message shapes are documented in the source header of `mouse-relay.mjs`.

## Security notes

- The relay validates tokens with **GitHub’s API** but does not store them.
- Only run this in environments you trust (e.g. **your Codespace**). Exposing the relay publicly without auth would be unsafe.

## License

See the parent Mouse repository for license terms.
