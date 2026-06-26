import type { Agent } from './Agent.ts'
import type { IRelay } from '../terminal/RelaySocket.ts'
import { XTermView } from '../terminal/XTermView.ts'

// Height threshold below which the module snaps to the compact bar
const COLLAPSE_PX = 80

export class AgentModule {
  el: HTMLElement
  readonly isAgent = true

  private barEl: HTMLElement
  private termWrap: HTMLElement
  private xterm: XTermView
  private collapsed = false
  private ro: ResizeObserver

  constructor(agent: Agent, relay: IRelay) {
    this.el = document.createElement('div')
    this.el.className = 'module agent-module'

    // Always-visible status bar
    this.barEl = document.createElement('div')
    this.barEl.className = 'agent-mod-bar'

    // Terminal area
    this.termWrap = document.createElement('div')
    this.termWrap.className = 'agent-mod-term'

    this.xterm = new XTermView()
    this.termWrap.appendChild(this.xterm.el)

    this.el.appendChild(this.barEl)
    this.el.appendChild(this.termWrap)

    // Wire up session output to the xterm
    this.xterm.addSession(relay, agent.id, agent.name)

    // Mount after first paint
    requestAnimationFrame(() => this.xterm.mount())

    // Keep bar updated as agent status changes
    agent.onChange(() => this.renderBar(agent))
    this.renderBar(agent)

    // Collapse/expand driven by rendered height
    this.ro = new ResizeObserver(() => {
      const h = this.el.offsetHeight
      const shouldCollapse = h < COLLAPSE_PX
      if (shouldCollapse !== this.collapsed) {
        this.collapsed = shouldCollapse
        this.el.classList.toggle('collapsed', this.collapsed)
        if (!this.collapsed) requestAnimationFrame(() => this.xterm.fit())
      }
    })
    this.ro.observe(this.el)

    // Tapping the bar when collapsed asks the stack to expand this module
    this.barEl.addEventListener('click', () => {
      if (this.collapsed) {
        this.el.dispatchEvent(new CustomEvent('agent-expand', { bubbles: true }))
      }
    })
  }

  // Called by ModuleStack — agents don't share the bash session
  connectTerminal(_relay: IRelay, _id: string, _label: string) { /* no-op */ }
  addAgentSession(_relay: IRelay, _id: string, _label: string)  { /* no-op */ }
  getTerminalView() { return null }
  fitTerminal()     { if (!this.collapsed) this.xterm.fit() }

  destroy() {
    this.ro.disconnect()
    this.xterm.destroy()
  }

  // ── Bar rendering ──────────────────────────────────

  private renderBar(agent: Agent) {
    const task     = escHtml(agent.task || agent.name)
    const subtitle = escHtml(this.subtitle(agent))
    const elapsed  = this.elapsed(agent)
    const icon     = this.iconClass(agent)

    this.barEl.innerHTML = `
      <div class="agent-icon ${icon}"></div>
      <div class="agent-row-text">
        <div class="agent-task-title">${task}</div>
        <div class="agent-subtitle">${subtitle}</div>
      </div>
      <div class="agent-elapsed">${elapsed}</div>
    `
  }

  private iconClass(agent: Agent): string {
    switch (agent.status) {
      case 'running':
      case 'thinking': return 'spinning'
      case 'waiting':  return 'waiting'
      case 'done':     return 'done'
      case 'error':    return 'error'
      default:         return 'idle'
    }
  }

  private subtitle(agent: Agent): string {
    const last = agent.messages.at(-1)
    if (last && last.type !== 'prompt') return last.text.slice(0, 80)
    switch (agent.status) {
      case 'running':  return 'Running...'
      case 'thinking': return 'Thinking...'
      case 'waiting':  return 'Waiting for input'
      case 'done':     return 'Done'
      case 'error':    return 'Error'
      default:         return 'Starting...'
    }
  }

  private elapsed(agent: Agent): string {
    const secs = Math.floor((Date.now() - agent.startedAt.getTime()) / 1000)
    if (secs < 10) return 'Now'
    if (secs < 60) return `${secs}s`
    return `${Math.floor(secs / 60)}m`
  }
}

function escHtml(s: string): string {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
}
