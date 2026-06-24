#!/usr/bin/env node
/**
 * Mouse Relay — multiplexed WebSocket PTY bridge.
 *
 * Two modes:
 *   • Codespaces (default): runs inside a GitHub Codespace, forwarded on port
 *     2222 to wss://{codespace}-2222.app.github.dev. Authenticates each WS by
 *     validating the GitHub token against api.github.com.
 *   • Local (--local or MOUSE_LOCAL=1): runs on any host you control (your Mac,
 *     a home server, a Jetson). Binds localhost by default; the phone connects
 *     to ws://<host>:2222 directly — NO GitHub Codespace, no port-forward proxy.
 *     Auth is a shared secret (MOUSE_RELAY_TOKEN) if set, else open on loopback.
 *
 * Agent execution is delegated to a pluggable runtime backend (see runtimes.mjs):
 * local subprocess (default), Docker container, or NVIDIA OpenShell/NemoClaw.
 *
 * Protocol (all frames are JSON text):
 *   C→S  { type:"auth",          token }
 *   S→C  { type:"auth_ok", mode, runtime }  |  { type:"auth_fail", reason }
 *   C→S  { type:"start_session", id, command:"bash"|"opencode", task? }
 *   S→C  { type:"session_started", id }
 *   C→S  { type:"input",         id, data }
 *   S→C  { type:"output",        id, data }
 *   C→S  { type:"resize",        id, cols, rows }
 *   C→S  { type:"kill_session",  id }
 *   S→C  { type:"session_exit",  id, code }
 *   S→C  { type:"error",         message }
 *
 * Health check: GET /health → 200 { ok:true, mode, runtime }
 */

import { createServer } from 'http'
import { WebSocketServer } from 'ws'
import { spawnSession, runtimeKind } from './runtimes.mjs'

const argv = process.argv.slice(2)
const LOCAL = argv.includes('--local') || process.env.MOUSE_LOCAL === '1'
const PORT  = parseInt(process.env.MOUSE_RELAY_PORT ?? '2222', 10)
// Local mode binds loopback by default (safe); override with MOUSE_RELAY_HOST
// (e.g. 0.0.0.0) to expose on the LAN. Codespaces mode must bind 0.0.0.0 so the
// GitHub port-forwarder can reach it.
const HOST = process.env.MOUSE_RELAY_HOST ?? (LOCAL ? '127.0.0.1' : '0.0.0.0')
// Optional shared-secret for local mode. When unset in local mode, loopback
// connections are allowed without auth (developer convenience).
const LOCAL_TOKEN = process.env.MOUSE_RELAY_TOKEN ?? ''
const MODE = LOCAL ? 'local' : 'codespaces'

function healthBody() {
  return JSON.stringify({ ok: true, version: '0.3.0', mode: MODE, runtime: runtimeKind() })
}

// ── HTTP server (health check + WS upgrade + permissive CORS for browsers) ──
const server = createServer((req, res) => {
  // Allow the web build (vite preview / packaged) to probe /health cross-origin.
  res.setHeader('Access-Control-Allow-Origin', '*')
  res.setHeader('Access-Control-Allow-Headers', '*')
  if (req.method === 'OPTIONS') { res.writeHead(204); res.end(); return }
  if (req.url === '/health') {
    res.writeHead(200, { 'Content-Type': 'application/json' })
    res.end(healthBody())
    return
  }
  res.writeHead(404); res.end()
})

const wss = new WebSocketServer({ server })

let listenErrorHandled = false
function handleListenError(err) {
  if (listenErrorHandled) return
  if (err && err.code === 'EADDRINUSE') {
    listenErrorHandled = true
    console.error(`[mouse-relay] Port ${PORT} is already in use (EADDRINUSE).`)
    console.error('[mouse-relay] Stop the process that is listening, then try again. Examples:')
    console.error(`[mouse-relay]   lsof -i :${PORT}`)
    console.error('[mouse-relay]   pkill -f mouse-relay')
    process.exit(1)
    return
  }
  listenErrorHandled = true
  console.error('[mouse-relay] Server error:', err)
  process.exit(1)
}
server.on('error', handleListenError)
wss.on('error', handleListenError)

/** Validate the auth frame for the active mode. Returns {ok, who, reason}. */
async function authenticate(token, remoteAddr) {
  if (MODE === 'local') {
    // Shared-secret if configured; otherwise allow loopback only.
    if (LOCAL_TOKEN) {
      if (token === LOCAL_TOKEN) return { ok: true, who: 'local' }
      return { ok: false, reason: 'invalid local token' }
    }
    const isLoopback = !remoteAddr
      || remoteAddr.includes('127.0.0.1') || remoteAddr.includes('::1')
    if (isLoopback) return { ok: true, who: 'local-loopback' }
    return { ok: false, reason: 'set MOUSE_RELAY_TOKEN to allow non-loopback clients' }
  }
  // Codespaces: validate the GitHub token.
  if (!token) return { ok: false, reason: 'missing token' }
  try {
    const r = await fetch('https://api.github.com/user', {
      headers: { Authorization: `Bearer ${token}`, Accept: 'application/vnd.github+json' },
    })
    if (!r.ok) return { ok: false, reason: 'invalid token' }
    const user = await r.json()
    return { ok: true, who: user.login }
  } catch {
    return { ok: false, reason: 'github unreachable' }
  }
}

wss.on('connection', (ws, req) => {
  /** @type {Map<string, import('node-pty').IPty>} */
  const sessions = new Map()
  const remoteAddr = req?.socket?.remoteAddress ?? ''

  const send  = (obj) => { try { ws.send(JSON.stringify(obj)) } catch {} }
  const error = (msg) => send({ type: 'error', message: msg })

  ws.once('message', async (raw) => {
    let msg
    try { msg = JSON.parse(raw.toString()) } catch { ws.close(); return }
    if (msg.type !== 'auth') { send({ type: 'auth_fail', reason: 'expected auth' }); ws.close(); return }

    const result = await authenticate(msg.token, remoteAddr)
    if (!result.ok) { send({ type: 'auth_fail', reason: result.reason }); ws.close(); return }
    console.log(`[relay] Authenticated (${MODE}/${runtimeKind()}): ${result.who}`)
    send({ type: 'auth_ok', mode: MODE, runtime: runtimeKind() })

    ws.on('message', (raw2) => {
      let m
      try { m = JSON.parse(raw2.toString()) } catch { return }
      switch (m.type) {
        case 'start_session': startSession(m);   break
        case 'input':         handleInput(m);    break
        case 'resize':        handleResize(m);   break
        case 'kill_session':  killSession(m.id); break
      }
    })
  })

  function startSession({ id, command, task, cols, rows }) {
    if (sessions.has(id)) { error(`Session "${id}" already exists`); return }
    let p
    try {
      p = spawnSession({ command, task, cols, rows })
    } catch (e) {
      error(`Failed to start session "${id}": ${e.message}`); return
    }
    sessions.set(id, p)
    send({ type: 'session_started', id })
    console.log(`[relay] Session started: ${id} (${command}) via ${runtimeKind()}`)

    p.onData((data) => send({ type: 'output', id, data }))
    p.onExit(({ exitCode }) => {
      sessions.delete(id)
      send({ type: 'session_exit', id, code: exitCode ?? null })
      console.log(`[relay] Session exited: ${id} (code ${exitCode})`)
    })

    if (command === 'opencode' && task) {
      setTimeout(() => { try { p.write(task + '\r') } catch {} }, 1200)
    }
  }

  function handleInput({ id, data }) {
    const p = sessions.get(id)
    if (!p) { error(`Unknown session: ${id}`); return }
    try { p.write(data) } catch {}
  }

  function handleResize({ id, cols, rows }) {
    const p = sessions.get(id)
    if (!p) return
    try { p.resize(Math.max(10, cols), Math.max(2, rows)) } catch {}
  }

  function killSession(id) {
    const p = sessions.get(id)
    if (!p) return
    try { p.kill() } catch {}
    sessions.delete(id)
    console.log(`[relay] Session killed: ${id}`)
  }

  ws.on('close', () => {
    for (const [id, p] of sessions) {
      try { p.kill() } catch {}
      console.log(`[relay] Killed session on disconnect: ${id}`)
    }
    sessions.clear()
  })
  ws.on('error', (e) => console.error('[relay] WebSocket error:', e.message))
})

server.listen(PORT, HOST, () => {
  console.log(`[mouse-relay] v0.3.0 — mode=${MODE} runtime=${runtimeKind()} — ${HOST}:${PORT}`)
  if (MODE === 'local') {
    console.log(`[mouse-relay] Connect the app to:  ws://${HOST === '0.0.0.0' ? '<this-host-ip>' : HOST}:${PORT}`)
    if (!LOCAL_TOKEN) console.log('[mouse-relay] No MOUSE_RELAY_TOKEN set — loopback clients allowed without auth.')
  } else {
    console.log(`[mouse-relay] Codespaces forwards to: wss://{codespace-name}-${PORT}.app.github.dev`)
  }
})
