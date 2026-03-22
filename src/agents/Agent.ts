export type AgentStatus = 'idle' | 'running' | 'thinking' | 'done' | 'waiting'

export interface AgentMsg {
  type: 'thinking' | 'action' | 'output' | 'question' | 'prompt'
  text: string
}

export class Agent {
  id: string
  name: string
  status: AgentStatus
  messages: AgentMsg[]
  cwd: string
  private listeners: (() => void)[] = []

  constructor(name: string, cwd = '~/project') {
    this.id = Math.random().toString(36).slice(2)
    this.name = name
    this.cwd = cwd
    this.status = 'idle'
    this.messages = []
  }

  onChange(fn: () => void) { this.listeners.push(fn) }
  private notify() { this.listeners.forEach(f => f()) }

  push(msg: AgentMsg) { this.messages.push(msg); this.notify() }

  async simulate(task: string) {
    const keyword = task.split(' ').at(-1) ?? task

    this.status = 'running'
    this.messages = []
    this.push({ type: 'prompt', text: `(base) user@codespace:${this.cwd} %` })
    this.notify()

    await delay(600)
    this.status = 'thinking'
    this.push({ type: 'thinking', text: 'Thinking...' })

    await delay(900)
    this.push({ type: 'action', text: `> Grepped codebase for "${keyword}"` })

    await delay(700)
    this.push({ type: 'action', text: `> Reading src/modules/Module.ts` })

    await delay(500)
    this.status = 'running'
    this.push({ type: 'output', text: `Found 3 matches. Analyzing context...` })

    await delay(1000)
    this.status = 'waiting'
    this.push({
      type: 'question',
      text: `I searched the codebase for "${keyword}" and found relevant code. Nothing on the internet yet — want me to search there too?`,
    })
    this.notify()
  }

  answer(yes: boolean) {
    if (this.status !== 'waiting') return
    if (yes) {
      this.status = 'running'
      this.push({ type: 'thinking', text: 'Searching the internet...' })
      delay(1500).then(() => {
        this.push({ type: 'output', text: 'Found 2 relevant results. Applying changes...' })
        delay(1000).then(() => { this.status = 'done'; this.notify() })
      })
    } else {
      this.status = 'done'
      this.notify()
    }
  }
}

function delay(ms: number) { return new Promise(r => setTimeout(r, ms)) }
