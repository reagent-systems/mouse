import { XTermView } from '../../terminal/XTermView.ts'
import type { IRelay } from '../../terminal/RelaySocket.ts'
import type { Agent } from '../../agents/Agent.ts'

export class AgentView {
  el: HTMLElement
  private xterm: XTermView
  private bar: HTMLElement
  private termWrap: HTMLElement
  private agent: Agent | null = null

  constructor() {
    this.el = document.createElement('div')
    this.el.className = 'view-agent'

    // Compact status bar — hidden until a session is connected
    this.bar = document.createElement('div')
    this.bar.className = 'agent-view-bar'
    this.bar.style.display = 'none'

    this.termWrap = document.createElement('div')
    this.termWrap.className = 'agent-view-term'

    this.xterm = new XTermView()
    this.termWrap.appendChild(this.xterm.el)

    this.el.appendChild(this.bar)
    this.el.appendChild(this.termWrap)
  }

  mount() {
    this.xterm.mount()
  }

  connect(relay: IRelay, agent: Agent) {
    this.agent = agent
    this.xterm.addSession(relay, agent.id, agent.name)
    agent.onChange(() => this.renderBar())
    this.bar.style.display = 'flex'
    this.renderBar()
  }

  /** True if no agent has been wired up yet */
  get idle() { return this.agent === null }

  fit()    { this.xterm.fit() }
  destroy(){ this.xterm.destroy() }

  private renderBar() {
    if (!this.agent) return
    const icon     = iconClass(this.agent)
    const task     = escHtml(this.agent.task || this.agent.name)
    const subtitle = escHtml(statusSubtitle(this.agent))

    this.bar.innerHTML = `
      <div class="agent-icon ${icon}"></div>
      <div class="agent-row-text">
        <div class="agent-task-title">${task}</div>
        <div class="agent-subtitle">${subtitle}</div>
      </div>
    `
  }
}

function iconClass(agent: Agent): string {
  switch (agent.status) {
    case 'running':
    case 'thinking': return 'spinning'
    case 'waiting':  return 'waiting'
    case 'done':     return 'done'
    case 'error':    return 'error'
    default:         return 'idle'
  }
}

function statusSubtitle(agent: Agent): string {
  const last = agent.messages.at(-1)
  if (last && last.type !== 'prompt') return last.text.slice(0, 80)
  switch (agent.status) {
    case 'running':  return 'Running...'
    case 'thinking': return 'Thinking...'
    case 'waiting':  return 'Waiting for input'
    case 'done':     return 'Done'
    case 'error':    return 'Error'
    default:         return 'Ready'
  }
}

function escHtml(s: string): string {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
}
