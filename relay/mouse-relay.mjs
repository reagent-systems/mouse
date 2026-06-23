#!/usr/bin/env node
/**
 * Mouse Relay — multiplexed WebSocket PTY bridge for GitHub Codespaces
 *
 * One WebSocket connection per user. Multiple named PTY sessions over it.
 *
 * Protocol (all frames are JSON text):
 *   C→S  { type:"auth",          token }
 *   S→C  { type:"auth_ok" }  |  { type:"auth_fail", reason }
 *
 *   C→S  { type:"start_session", id, command:"bash"|"opencode", task? }
 *   S→C  { type:"session_started", id }
 *
 *   C→S  { type:"input",         id, data }
 *   S→C  { type:"output",        id, data }
 *
 *   C→S  { type:"resize",        id, cols, rows }
 *   C→S  { type:"kill_session",  id }
 *   S→C  { type:"session_exit",  id, code }
 *
 *   C→S  { type:"exec",          id, command, cwd? }
 *   S→C  { type:"exec_result",   id, stdout, stderr, code }
 *
 *   S→C  { type:"error",         message }
 *
 * Health check: GET /health → 200 { ok:true }
 */

import { createServer } from 'http'
import { WebSocketServer } from 'ws'
import { exec as cpExec } from 'child_process'
import { readdirSync, statSync } from 'fs'
import pty from 'node-pty'

const PORT  = parseInt(process.env.MOUSE_RELAY_PORT ?? '2222', 10)
const SHELL = process.env.SHELL ?? '/bin/bash'
const VERSION = '0.3.0'

/** Best-effort repository working directory for one-shot `exec` commands. */
let cachedCwd = null
function defaultCwd() {
  if (cachedCwd) return cachedCwd
  try {
    for (const entry of readdirSync('/workspaces')) {
      const full = `/workspaces/${entry}`
      try { if (statSync(full).isDirectory()) { cachedCwd = full; return cachedCwd } } catch { /* skip */ }
    }
  } catch { /* /workspaces missing (non-Codespace) */ }
  cachedCwd = process.env.HOME ?? process.cwd()
  return cachedCwd
}

// ── HTTP server (health check + WS upgrade) ────────────
const server = createServer((req, res) => {
  if (req.url === '/health') {
    res.writeHead(200, { 'Content-Type': 'application/json' })
    res.end(JSON.stringify({ ok: true, version: VERSION }))
    return
  }
  res.writeHead(404); res.end()
})

const wss = new WebSocketServer({ server })

/** `ws` forwards HTTP listen errors here; without a listener they become an unhandled rejection on wss. */
let listenErrorHandled = false
function handleListenError(err) {
  if (listenErrorHandled) return
  if (err && err.code === 'EADDRINUSE') {
    listenErrorHandled = true
    console.error(`[mouse-relay] Port ${PORT} is already in use (EADDRINUSE).`)
    console.error('[mouse-relay] Stop the process that is listening, then try again. Examples:')
    console.error(`[mouse-relay]   ss -tlnp | grep :${PORT}`)
    console.error('[mouse-relay]   pkill -f mouse-relay   # or: pkill -f "node.*2222"')
    console.error(`[mouse-relay]   fuser -v -k ${PORT}/tcp  # may need: sudo fuser -k ${PORT}/tcp`)
    console.error(`[mouse-relay]   lsof -i :${PORT}`)
    if (PORT === 2222) {
      console.error('[mouse-relay] Mouse expects port 2222 in the Codespace URL; change MOUSE_RELAY_PORT only if you change Mouse too.')
    }
    process.exit(1)
    return
  }
  listenErrorHandled = true
  console.error('[mouse-relay] Server error:', err)
  process.exit(1)
}
server.on('error', handleListenError)
wss.on('error', handleListenError)

wss.on('connection', (ws) => {
  /** @type {Map<string, import('node-pty').IPty>} */
  const sessions = new Map()

  const send  = (obj) => { try { ws.send(JSON.stringify(obj)) } catch {} }
  const error = (msg) => send({ type: 'error', message: msg })

  // ── Auth handshake ──────────────────────────────────
  ws.once('message', async (raw) => {
    let msg
    try { msg = JSON.parse(raw.toString()) } catch { ws.close(); return }

    if (msg.type !== 'auth' || !msg.token) {
      send({ type: 'auth_fail', reason: 'missing token' }); ws.close(); return
    }

    try {
      const r = await fetch('https://api.github.com/user', {
        headers: { Authorization: `Bearer ${msg.token}`, Accept: 'application/vnd.github+json' },
      })
      if (!r.ok) throw new Error('invalid')
      const user = await r.json()
      console.log(`[relay] Authenticated: ${user.login}`)
    } catch {
      send({ type: 'auth_fail', reason: 'invalid token' }); ws.close(); return
    }

    send({ type: 'auth_ok' })

    // ── Route subsequent messages ─────────────────────
    ws.on('message', (raw) => {
      let msg
      try { msg = JSON.parse(raw.toString()) } catch { return }

      switch (msg.type) {
        case 'start_session': startSession(msg);   break
        case 'input':         handleInput(msg);    break
        case 'resize':        handleResize(msg);   break
        case 'kill_session':  killSession(msg.id); break
        case 'exec':          handleExec(msg);     break
      }
    })
  })

  // ── One-shot command execution (powers file/git panels) ──
  function handleExec({ id, command, cwd }) {
    if (typeof command !== 'string' || !command) {
      send({ type: 'exec_result', id, stdout: '', stderr: 'missing command', code: 1 })
      return
    }
    cpExec(
      command,
      {
        cwd: cwd || defaultCwd(),
        env: { ...process.env },
        shell: SHELL,
        maxBuffer: 16 * 1024 * 1024,
        timeout: 20000,
      },
      (err, stdout, stderr) => {
        const code = err ? (typeof err.code === 'number' ? err.code : 1) : 0
        send({
          type: 'exec_result',
          id,
          stdout: stdout?.toString() ?? '',
          stderr: (stderr?.toString() ?? '') || (err && code !== 0 ? String(err.message ?? '') : ''),
          code,
        })
      },
    )
  }

  // ── Session management ──────────────────────────────
  function startSession({ id, command, task }) {
    if (sessions.has(id)) { error(`Session "${id}" already exists`); return }

    const isOpencode = command === 'opencode'
    const cmd  = isOpencode ? 'opencode' : SHELL
    const args = isOpencode ? [] : ['-l']

    let p
    try {
      p = pty.spawn(cmd, args, {
        name: 'xterm-256color',
        cols: 220, rows: 50,
        cwd: process.env.HOME ?? '/workspaces',
        env: { ...process.env, TERM: 'xterm-256color' },
      })
    } catch (e) {
      error(`Failed to start "${cmd}": ${e.message}`); return
    }

    sessions.set(id, p)
    send({ type: 'session_started', id })
    console.log(`[relay] Session started: ${id} (${cmd})`)

    p.onData((data) => {
      send({ type: 'output', id, data })
    })

    p.onExit(({ exitCode }) => {
      sessions.delete(id)
      send({ type: 'session_exit', id, code: exitCode ?? null })
      console.log(`[relay] Session exited: ${id} (code ${exitCode})`)
    })

    // Auto-send task to opencode after it initialises
    if (isOpencode && task) {
      setTimeout(() => {
        try { p.write(task + '\r') } catch {}
      }, 1200)
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

  // ── Cleanup on disconnect ───────────────────────────
  ws.on('close', () => {
    for (const [id, p] of sessions) {
      try { p.kill() } catch {}
      console.log(`[relay] Killed session on disconnect: ${id}`)
    }
    sessions.clear()
  })

  ws.on('error', (e) => console.error('[relay] WebSocket error:', e.message))
})

server.listen(PORT, '0.0.0.0', () => {
  console.log(`[mouse-relay] v${VERSION} — port ${PORT}`)
  console.log(`[mouse-relay] GitHub Codespaces forwards to:`)
  console.log(`[mouse-relay]   wss://{codespace-name}-${PORT}.app.github.dev`)
})
