import { Agent } from './Agent.ts'

export class AgentPanel {
  el: HTMLElement
  private agents: Agent[] = []
  private expandedId: string | null = null
  private barEls = new Map<string, HTMLElement>()

  constructor() {
    this.el = document.createElement('div')
    this.el.className = 'agents-panel'
  }

  addAgent(agent: Agent) {
    this.agents.push(agent)
    const bar = this.makeBar(agent)
    this.barEls.set(agent.id, bar)
    this.el.appendChild(bar)
    agent.onChange(() => this.updateBar(agent))
  }

  get count() { return this.agents.length }

  private makeBar(agent: Agent): HTMLElement {
    const bar = document.createElement('div')
    bar.className = 'agent-bar'
    bar.dataset.id = agent.id

    const hdr = document.createElement('div')
    hdr.className = 'agent-bar-hdr'
    hdr.innerHTML = `
      <div class="agent-dot ${agent.status}"></div>
      <span class="agent-name">${agent.name}</span>
      <span class="agent-status-text">${this.statusLabel(agent)}</span>
      <span class="agent-chevron">›</span>
    `

    const body = document.createElement('div')
    body.className = 'agent-body'

    bar.appendChild(hdr)
    bar.appendChild(body)

    hdr.addEventListener('click', () => {
      const isExpanded = bar.classList.contains('expanded')
      this.el.querySelectorAll('.agent-bar').forEach(b => b.classList.remove('expanded'))
      if (!isExpanded) {
        bar.classList.add('expanded')
        this.expandedId = agent.id
      } else {
        this.expandedId = null
      }
      this.updateChevrons()
    })

    return bar
  }

  private updateBar(agent: Agent) {
    const bar = this.barEls.get(agent.id)
    if (!bar) return

    bar.querySelector<HTMLElement>('.agent-dot')!.className = `agent-dot ${agent.status}`
    bar.querySelector<HTMLElement>('.agent-status-text')!.textContent = this.statusLabel(agent)

    const body = bar.querySelector<HTMLElement>('.agent-body')!
    body.innerHTML = this.renderBody(agent)

    // Wire answer buttons
    if (agent.status === 'waiting') {
      body.querySelector('#yes-btn')?.addEventListener('click', (e) => {
        e.stopPropagation()
        agent.answer(true)
      })
      body.querySelector('#no-btn')?.addEventListener('click', (e) => {
        e.stopPropagation()
        agent.answer(false)
      })
    }

    // Auto-expand while active
    if ((agent.status === 'running' || agent.status === 'thinking' || agent.status === 'waiting')
        && this.expandedId === null) {
      bar.classList.add('expanded')
      this.expandedId = agent.id
      this.updateChevrons()
    }

    // Scroll body to bottom
    body.scrollTop = body.scrollHeight
  }

  private renderBody(agent: Agent): string {
    return agent.messages.map(m => {
      switch (m.type) {
        case 'prompt':
          return `<div class="agent-prompt">${m.text}</div>`
        case 'thinking':
          return `<div class="agent-msg thinking"><span class="agent-think-dot"></span>${m.text}</div>`
        case 'action':
          return `<div class="agent-action">${m.text}</div>`
        case 'output':
          return `<div class="agent-msg">${m.text}</div>`
        case 'question':
          return `
            <div class="agent-question">
              <p>${m.text}</p>
              ${agent.status === 'waiting' ? `
                <div class="agent-answer-btns">
                  <button class="agent-answer-btn yes" id="yes-btn">Yes</button>
                  <button class="agent-answer-btn no" id="no-btn">No</button>
                </div>
              ` : ''}
            </div>
          `
        default:
          return ''
      }
    }).join('')
  }

  private updateChevrons() {
    this.el.querySelectorAll('.agent-bar').forEach(bar => {
      const chevron = bar.querySelector<HTMLElement>('.agent-chevron')
      if (chevron) chevron.style.transform = bar.classList.contains('expanded') ? 'rotate(90deg)' : ''
    })
  }

  private statusLabel(agent: Agent): string {
    switch (agent.status) {
      case 'running':  return 'Running...'
      case 'thinking': return 'Thinking...'
      case 'waiting':  return 'Waiting for input'
      case 'done':     return 'Done'
      default:         return 'Idle'
    }
  }
}
