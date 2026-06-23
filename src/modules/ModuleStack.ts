import { Module } from './Module.ts'
import type { ViewType } from './Module.ts'
import type { Agent } from '../agents/Agent.ts'
import type { RelaySocket } from '../terminal/RelaySocket.ts'
import type { RepoService } from '../codespaces/RepoService.ts'
import type { XTermView } from '../terminal/XTermView.ts'
import { onDragY, onPinchSpread } from '../gestures/index.ts'

const INITIAL_VIEWS: ViewType[] = ['code', 'changes']
const MIN_FLEX = 0.5
const ANIM_MS  = 300

export class ModuleStack {
  el: HTMLElement
  private modules: Module[] = []
  private flexes: number[] = []
  private cleanups: (() => void)[] = []
  private repo: RepoService | null = null

  constructor() {
    this.el = document.createElement('div')
    this.el.className = 'module-stack'
    INITIAL_VIEWS.forEach(v => this.addModule(v, false))
    this.bindPinchSpread()
  }

  connectTerminal(relay: RelaySocket, sessionId: string, label = 'Terminal') {
    this.modules.forEach(m => m.connectTerminal(relay, sessionId, label))
  }

  /** Provide a live Codespace repo to every module's file/git panels. */
  connectRepo(repo: RepoService) {
    this.repo = repo
    this.modules.forEach(m => m.connectRepo(repo))
  }

  /**
   * Wire an agent to an agent view slot.
   * Uses an existing idle agent view if one is visible, otherwise adds a new module.
   */
  addAgent(agent: Agent, relay: RelaySocket) {
    const idle = this.modules.find(m => m.hasIdleAgentView())
    if (idle) {
      idle.connectAgent(relay, agent)
    } else {
      this.addModule('agent')
      const mod = this.modules.at(-1)!
      mod.connectAgent(relay, agent)
    }
  }

  getTerminalView(): XTermView | null {
    for (const m of this.modules) {
      const v = m.getTerminalView()
      if (v) return v
    }
    return null
  }

  fitTerminals() { this.modules.forEach(m => m.fitTerminal()) }

  // ── Private ──────────────────────────────────────────

  private addModule(view: ViewType, animate = true) {
    const mod = new Module(view)
    if (this.repo) mod.connectRepo(this.repo)
    if (animate) {
      mod.el.style.transition = `flex ${ANIM_MS}ms cubic-bezier(0.34,1.56,0.64,1), opacity ${ANIM_MS}ms`
      mod.el.style.opacity = '0'
      mod.el.style.flex = '0'
      requestAnimationFrame(() => requestAnimationFrame(() => {
        mod.el.style.opacity = '1'
        mod.el.style.flex = '1'
        setTimeout(() => { mod.el.style.transition = '' }, ANIM_MS)
      }))
    }
    this.modules.push(mod)
    this.flexes.push(1)
    if (this.modules.length > 1) this.el.appendChild(this.makeDivider(this.modules.length - 2))
    this.el.appendChild(mod.el)
    this.applyFlex()
  }

  private removeModule(index: number) {
    if (this.modules.length <= 1) return
    const mod = this.modules[index]
    mod.el.style.transition = `flex ${ANIM_MS}ms ease, opacity ${ANIM_MS}ms ease`
    mod.el.style.opacity = '0'
    mod.el.style.flex = '0'
    mod.el.style.minHeight = '0'
    setTimeout(() => {
      mod.destroy()
      this.modules.splice(index, 1)
      this.flexes.splice(index, 1)
      this.rebuildDOM()
    }, ANIM_MS)
  }

  private rebuildDOM() {
    this.cleanups.forEach(c => c())
    this.cleanups = []
    this.el.innerHTML = ''
    this.modules.forEach((mod, i) => {
      if (i > 0) this.el.appendChild(this.makeDivider(i - 1))
      this.el.appendChild(mod.el)
    })
    this.applyFlex()
  }

  private makeDivider(aboveIndex: number): HTMLElement {
    const d = document.createElement('div')
    d.className = 'module-divider'
    const cleanup = onDragY(d, (dy) => {
      d.classList.add('dragging')
      const stackH   = this.el.offsetHeight
      const totalFlex = this.flexes.reduce((a, b) => a + b, 0)
      const delta    = (dy / stackH) * totalFlex
      const a = Math.max(MIN_FLEX, this.flexes[aboveIndex]     + delta)
      const b = Math.max(MIN_FLEX, this.flexes[aboveIndex + 1] - delta)
      this.flexes[aboveIndex]     = a
      this.flexes[aboveIndex + 1] = b
      this.applyFlex()
    })
    d.addEventListener('mouseup',  () => d.classList.remove('dragging'))
    d.addEventListener('touchend', () => d.classList.remove('dragging'))
    this.cleanups.push(cleanup)
    return d
  }

  private applyFlex() {
    this.modules.forEach((mod, i) => { mod.el.style.flex = String(this.flexes[i]) })
  }

  private bindPinchSpread() {
    const views: ViewType[] = ['graph', 'terminal', 'files', 'changes', 'code']
    onPinchSpread(this.el, (type) => {
      if (type === 'spread') this.addModule(views[this.modules.length % views.length])
      else                   this.removeModule(this.modules.length - 1)
    })
  }
}
