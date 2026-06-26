import type { IRelay } from '../terminal/RelaySocket.ts'

export type AgentStatus = 'idle' | 'running' | 'thinking' | 'waiting' | 'done' | 'error'

export interface AgentMsg {
  type: 'thinking' | 'action' | 'output' | 'question' | 'prompt'
  text: string
}

// Strip ANSI escape codes from terminal output
const ANSI_RE = /\x1b\[[0-9;]*[A-Za-z]|\x1b[^[]/g
function stripAnsi(s: string) { return s.replace(ANSI_RE, '') }

// opencode output patterns
const PAT_THINKING = /thinking|processing|analyzing|⠋|⠙|⠹|⠸|⠼|⠴|⠦|⠧|⠇|⠏/i
const PAT_ACTION   = /^>\s|^running:|^reading |^writing |^editing |^searching |^bash\(|^tool:/i
const PAT_WAITING  = /\?\s*$|\[y\/n\]|\[Y\/n\]|\[y\/N\]/i
const PAT_DONE     = /task complete|done\.|all done|finished/i

export class Agent {
  id: string
  name: string
  task = ''
  status: AgentStatus = 'idle'
  messages: AgentMsg[] = []
  cwd: string
  startedAt: Date = new Date()

  private relay: IRelay
  private listeners: (() => void)[] = []
  private unsubs: (() => void)[] = []
  private lineBuffer: string[] = []

  constructor(id: string, name: string, relay: IRelay, cwd = '~/project') {
    this.id = id
    this.name = name
    this.relay = relay
    this.cwd = cwd
  }

  onChange(fn: () => void) { this.listeners.push(fn) }
  private notify() { this.listeners.forEach(f => f()) }

  push(msg: AgentMsg) { this.messages.push(msg); this.notify() }

  start(task: string) {
    this.task = task
    this.startedAt = new Date()
    this.status = 'running'
    this.messages = []
    this.lineBuffer = []
    this.push({ type: 'prompt', text: `user@codespace:${this.cwd} % opencode` })
    this.notify()

    // Ask relay to start an opencode session
    this.relay.startSession(this.id, 'opencode', task)

    // Subscribe to output
    const unsubData = this.relay.onSessionData(this.id, (data) => this.onData(data))
    const unsubExit = this.relay.onSessionExit(this.id, (code) => this.onExit(code))
    this.unsubs.push(unsubData, unsubExit)
  }

  /** Send a reply to opencode (e.g. answering y/n) */
  answer(text: string) {
    if (this.status !== 'waiting') return
    this.status = 'running'
    this.relay.sendInput(this.id, text + '\r')
    this.notify()
  }

  stop() {
    this.relay.killSession(this.id)
    this.unsubs.forEach(fn => fn())
    this.unsubs = []
    this.status = 'done'
    this.notify()
  }

  // ── Output parser ────────────────────────────────────

  private pending = ''

  private onData(raw: string) {
    // Accumulate into line buffer, handling \r overwrites
    this.pending += raw
    const parts = this.pending.split(/\n/)
    this.pending = parts.pop() ?? ''

    for (const part of parts) {
      // Handle carriage return (line overwrite)
      const segments = part.split('\r')
      const line = stripAnsi(segments.at(-1) ?? '').trim()
      if (line) this.processLine(line)
    }
  }

  private processLine(line: string) {
    this.lineBuffer.push(line)
    if (this.lineBuffer.length > 300) this.lineBuffer.shift()

    // Detect status transitions
    if (PAT_WAITING.test(line)) {
      if (this.status !== 'waiting') {
        this.status = 'waiting'
        // Replace last thinking msg or push question
        const last = this.messages.at(-1)
        if (last?.type === 'thinking') {
          last.type = 'question'
          last.text = line
        } else {
          this.push({ type: 'question', text: line })
        }
        this.notify()
        return
      }
    } else if (PAT_DONE.test(line)) {
      this.status = 'done'
      this.push({ type: 'output', text: line })
      this.notify()
      return
    } else if (PAT_ACTION.test(line)) {
      this.status = 'running'
      this.push({ type: 'action', text: line })
      this.notify()
      return
    } else if (PAT_THINKING.test(line)) {
      this.status = 'thinking'
      // Update existing thinking message in place rather than adding duplicates
      const last = this.messages.at(-1)
      if (last?.type === 'thinking') {
        last.text = line
      } else {
        this.push({ type: 'thinking', text: line })
      }
      this.notify()
      return
    }

    // Plain output — only push non-empty meaningful lines
    if (line.length > 2 && this.status !== 'idle') {
      const last = this.messages.at(-1)
      if (last?.type === 'output' && this.messages.length > 2) {
        // Coalesce consecutive output lines to avoid flooding the panel
        last.text = line
      } else {
        this.push({ type: 'output', text: line })
      }
      this.notify()
    }
  }

  private onExit(code: number | null) {
    this.unsubs.forEach(fn => fn())
    this.unsubs = []
    this.status = code === 0 ? 'done' : 'error'
    this.notify()
  }
}
