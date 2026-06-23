export type RelayStatus = 'connecting' | 'authenticating' | 'connected' | 'disconnected' | 'error'
type Unsub = () => void

export interface ExecResult {
  stdout: string
  stderr: string
  code: number
}

export class RelaySocket {
  private ws: WebSocket | null = null
  private _status: RelayStatus = 'disconnected'
  private statusHandlers: ((s: RelayStatus) => void)[] = []
  private url: string
  private token: string

  // Per-session handler maps
  private dataHandlers  = new Map<string, Set<(data: string) => void>>()
  private exitHandlers  = new Map<string, Set<(code: number | null) => void>>()
  private startHandlers = new Map<string, Set<() => void>>()

  // Pending one-shot exec requests, keyed by request id
  private execPending = new Map<string, (r: ExecResult) => void>()
  private execSeq = 0

  constructor(url: string, token: string) {
    this.url = url
    this.token = token
  }

  get status(): RelayStatus { return this._status }

  onStatus(fn: (s: RelayStatus) => void): Unsub {
    this.statusHandlers.push(fn)
    return () => { this.statusHandlers = this.statusHandlers.filter(h => h !== fn) }
  }

  // ── Session subscriptions ───────────────────────────

  onSessionData(id: string, fn: (data: string) => void): Unsub {
    if (!this.dataHandlers.has(id)) this.dataHandlers.set(id, new Set())
    this.dataHandlers.get(id)!.add(fn)
    return () => this.dataHandlers.get(id)?.delete(fn)
  }

  onSessionExit(id: string, fn: (code: number | null) => void): Unsub {
    if (!this.exitHandlers.has(id)) this.exitHandlers.set(id, new Set())
    this.exitHandlers.get(id)!.add(fn)
    return () => this.exitHandlers.get(id)?.delete(fn)
  }

  onSessionStarted(id: string, fn: () => void): Unsub {
    if (!this.startHandlers.has(id)) this.startHandlers.set(id, new Set())
    this.startHandlers.get(id)!.add(fn)
    return () => this.startHandlers.get(id)?.delete(fn)
  }

  // ── Session control ─────────────────────────────────

  startSession(id: string, command: 'bash' | 'opencode', task?: string) {
    this.sendJSON({ type: 'start_session', id, command, task })
  }

  killSession(id: string) {
    this.sendJSON({ type: 'kill_session', id })
  }

  sendInput(id: string, data: string) {
    if (this._status !== 'connected') return
    this.sendJSON({ type: 'input', id, data })
  }

  /** Convenience: types text + Enter into a session */
  sendMessage(id: string, text: string) {
    this.sendInput(id, text + '\r')
  }

  resize(id: string, cols: number, rows: number) {
    this.sendJSON({ type: 'resize', id, cols, rows })
  }

  /**
   * Run a single command in the Codespace and resolve with its output.
   * Used by the file/git panels. Rejects if the relay is not connected or
   * does not answer in time (e.g. an older relay without `exec` support).
   */
  exec(command: string, timeoutMs = 20000): Promise<ExecResult> {
    return new Promise((resolve, reject) => {
      if (this._status !== 'connected') {
        reject(new Error('Not connected to a Codespace'))
        return
      }
      const id = `exec-${++this.execSeq}`
      const timer = setTimeout(() => {
        if (this.execPending.delete(id)) {
          reject(new Error('Command timed out (relay may need updating to @mouse-app/relay@latest)'))
        }
      }, timeoutMs)
      this.execPending.set(id, (r) => {
        clearTimeout(timer)
        resolve(r)
      })
      this.sendJSON({ type: 'exec', id, command })
    })
  }

  // ── Connection lifecycle ────────────────────────────

  connect() {
    if (this.ws) this.ws.close()
    this.setStatus('connecting')

    this.ws = new WebSocket(this.url)

    this.ws.onopen = () => {
      this.setStatus('authenticating')
      this.sendJSON({ type: 'auth', token: this.token })
    }

    this.ws.onmessage = (event) => {
      let msg: any
      try { msg = JSON.parse(event.data) } catch { return }
      this.route(msg)
    }

    this.ws.onerror = () => this.setStatus('error')
    this.ws.onclose = () => {
      if (this._status !== 'error') this.setStatus('disconnected')
    }
  }

  disconnect() {
    this.ws?.close()
    this.ws = null
    this.setStatus('disconnected')
  }

  // ── Internal ────────────────────────────────────────

  private route(msg: any) {
    switch (msg.type) {
      case 'auth_ok':
        this.setStatus('connected')
        break
      case 'auth_fail':
        this.setStatus('error')
        this.ws?.close()
        break
      case 'session_started':
        this.startHandlers.get(msg.id)?.forEach(fn => fn())
        break
      case 'output':
        this.dataHandlers.get(msg.id)?.forEach(fn => fn(msg.data))
        break
      case 'session_exit':
        this.exitHandlers.get(msg.id)?.forEach(fn => fn(msg.code ?? null))
        break
      case 'exec_result': {
        const handler = this.execPending.get(msg.id)
        if (handler) {
          this.execPending.delete(msg.id)
          handler({
            stdout: typeof msg.stdout === 'string' ? msg.stdout : '',
            stderr: typeof msg.stderr === 'string' ? msg.stderr : '',
            code: typeof msg.code === 'number' ? msg.code : 0,
          })
        }
        break
      }
    }
  }

  private sendJSON(obj: object) {
    if (this.ws?.readyState === WebSocket.OPEN) {
      this.ws.send(JSON.stringify(obj))
    }
  }

  private setStatus(s: RelayStatus) {
    this._status = s
    if (s === 'disconnected' || s === 'error') {
      // Resolve any in-flight exec calls so the panels surface an error instead of hanging.
      const pending = [...this.execPending.values()]
      this.execPending.clear()
      pending.forEach(fn => fn({ stdout: '', stderr: 'Connection lost', code: 1 }))
    }
    this.statusHandlers.forEach(fn => fn(s))
  }
}
