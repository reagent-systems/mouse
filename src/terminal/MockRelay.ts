import type { RelayStatus, IRelay } from './RelaySocket.ts'

type Unsub = () => void

/** Demo relays satisfy the same {@link IRelay} contract as the live socket. */
export type RelayLike = IRelay

/**
 * MockRelay — a drop-in stand-in for {@link RelaySocket} used by demo mode
 * (URL `?demo=1`). It satisfies the same public surface the app calls, but
 * instead of a real WebSocket it streams scripted PTY output so every view —
 * terminal, agent panels, status bars — renders and animates with no live
 * GitHub Codespace. This is what makes the UI verifiable headlessly.
 */
export class MockRelay implements IRelay {
  private _status: RelayStatus = 'disconnected'
  private statusHandlers: ((s: RelayStatus) => void)[] = []
  private dataHandlers  = new Map<string, Set<(data: string) => void>>()
  private exitHandlers  = new Map<string, Set<(code: number | null) => void>>()
  private startHandlers = new Map<string, Set<() => void>>()
  private timers: ReturnType<typeof setTimeout>[] = []

  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  constructor(_url = '', _token = '') {}

  get status(): RelayStatus { return this._status }

  onStatus(fn: (s: RelayStatus) => void): Unsub {
    this.statusHandlers.push(fn)
    return () => { this.statusHandlers = this.statusHandlers.filter(h => h !== fn) }
  }

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

  connect() {
    this.setStatus('connecting')
    this.schedule(120, () => this.setStatus('authenticating'))
    this.schedule(260, () => this.setStatus('connected'))
  }

  disconnect() {
    this.timers.forEach(clearTimeout)
    this.timers = []
    this.setStatus('disconnected')
  }

  startSession(id: string, command: 'bash' | 'opencode', task?: string) {
    this.schedule(80, () => this.startHandlers.get(id)?.forEach(fn => fn()))
    if (command === 'bash') this.streamBash(id)
    else this.streamOpencode(id, task ?? 'Run task')
  }

  killSession(id: string) {
    this.exit(id, 0)
  }

  sendInput(id: string, data: string) {
    // Echo answers (e.g. y/n) back into the stream so the demo feels live.
    const clean = data.replace(/[\r\n]/g, '')
    if (clean) this.emit(id, `\x1b[2m${clean}\x1b[0m\r\n`)
    if (/^y/i.test(clean)) {
      this.schedule(400, () => this.emit(id, '\x1b[36m> Searching the web…\x1b[0m\r\n'))
      this.schedule(1200, () => this.emit(id, '\x1b[32mFound 3 results. Task complete.\x1b[0m\r\n'))
    }
  }

  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  resize(_id: string, _cols: number, _rows: number) { /* no-op in demo */ }

  sendMessage(id: string, text: string) { this.sendInput(id, text + '\r') }

  // ── Scripted streams ────────────────────────────────

  private streamBash(id: string) {
    const lines = [
      '\x1b[2m  Codespace ready.\x1b[0m\r\n',
      '\x1b[32m(base) \x1b[34muser@codespace\x1b[0m:\x1b[34m~/project\x1b[0m % ',
    ]
    let t = 200
    lines.forEach((l) => { this.schedule(t, () => this.emit(id, l)); t += 220 })
  }

  private streamOpencode(id: string, task: string) {
    const seq: [number, string][] = [
      [200,  `\x1b[32m(base) \x1b[34muser@codespace\x1b[0m:\x1b[34m~/project\x1b[0m % opencode\r\n`],
      [500,  `\x1b[2mThinking…\x1b[0m\r\n`],
      [1100, `\x1b[36m> Grepped codebase for "${task.slice(0, 24)}"\x1b[0m\r\n`],
      [1700, `\x1b[36m> Read 4 files\x1b[0m\r\n`],
      [2300, `\x1b[2mThinking…\x1b[0m\r\n`],
      [3000, `I searched the codebase and nothing came up.\r\n`],
      [3300, `Would you like me to search the internet for it? \x1b[33m[y/n]\x1b[0m `],
    ]
    seq.forEach(([d, s]) => this.schedule(d, () => this.emit(id, s)))
  }

  // ── Internal ────────────────────────────────────────

  private emit(id: string, data: string) {
    this.dataHandlers.get(id)?.forEach(fn => fn(data))
  }

  private exit(id: string, code: number | null) {
    this.exitHandlers.get(id)?.forEach(fn => fn(code))
  }

  private schedule(ms: number, fn: () => void) {
    this.timers.push(setTimeout(fn, ms))
  }

  private setStatus(s: RelayStatus) {
    this._status = s
    this.statusHandlers.forEach(fn => fn(s))
  }
}
