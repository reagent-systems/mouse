import { onLiveSwipe } from '../gestures/index.ts'
import { CodeEditorView } from './views/CodeEditor.ts'
import { FileTreeView } from './views/FileTree.ts'
import { GitChangesView } from './views/GitChanges.ts'
import { GitGraphView } from './views/GitGraph.ts'
import { AgentView } from './views/AgentView.ts'
import { XTermView } from '../terminal/XTermView.ts'
import type { RelaySocket } from '../terminal/RelaySocket.ts'
import type { RepoService } from '../codespaces/RepoService.ts'
import type { Agent } from '../agents/Agent.ts'

export type ViewType = 'code' | 'files' | 'changes' | 'graph' | 'terminal' | 'agent'
const VIEWS: ViewType[] = ['code', 'files', 'changes', 'graph', 'terminal', 'agent']

export class Module {
  el: HTMLElement
  private contentEl: HTMLElement
  private trackEl: HTMLElement
  private viewIndex: number
  private instances: Partial<Record<ViewType, { el: HTMLElement }>> = {}
  private xtermView: XTermView | null = null
  private agentView: AgentView | null = null
  private repo: RepoService | null = null
  private cleanup: (() => void) | null = null

  constructor(initialView: ViewType = 'code') {
    this.viewIndex = VIEWS.indexOf(initialView)

    this.el = document.createElement('div')
    this.el.className = 'module'

    this.contentEl = document.createElement('div')
    this.contentEl.className = 'module-content'

    this.trackEl = document.createElement('div')
    this.trackEl.className = 'view-track'
    this.trackEl.style.width = `${VIEWS.length * 100}%`
    this.trackEl.style.transition = 'transform 0.28s cubic-bezier(0.25,0.46,0.45,0.94)'
    this.trackEl.style.transform = `translateX(-${this.viewIndex * (100 / VIEWS.length)}%)`

    VIEWS.forEach((v) => {
      const slot = document.createElement('div')
      slot.className = 'view-slot'
      slot.style.width = `${100 / VIEWS.length}%`
      slot.dataset.view = v
      this.trackEl.appendChild(slot)
    })

    this.contentEl.appendChild(this.trackEl)
    this.el.appendChild(this.contentEl)

    this.mountView(this.viewIndex)
    this.bindGestures()
  }

  private getSlot(i: number): HTMLElement {
    return this.trackEl.children[i] as HTMLElement
  }

  private mountView(i: number) {
    const v = VIEWS[i]
    if (this.instances[v]) return
    const view = this.createView(v)
    this.instances[v] = view
    this.getSlot(i).appendChild(view.el)

    if (v === 'terminal' && view instanceof XTermView) {
      this.xtermView = view
      view.mount()
    }
    if (v === 'agent' && view instanceof AgentView) {
      this.agentView = view
      view.mount()
    }
    if (v === 'files' && view instanceof FileTreeView) {
      view.onOpenFile((path) => this.openFileInCode(path))
    }
    if (this.repo) this.applyRepo(v)
  }

  /** Pass the live repo to a repo-aware view if it supports it. */
  private applyRepo(v: ViewType) {
    if (!this.repo) return
    const view = this.instances[v] as { connectRepo?: (r: RepoService) => void } | undefined
    view?.connectRepo?.(this.repo)
  }

  /** Provide a live Codespace repo to all current and future repo-aware views. */
  connectRepo(repo: RepoService) {
    this.repo = repo
    ;(['code', 'files', 'changes', 'graph'] as ViewType[]).forEach(v => {
      if (this.instances[v]) this.applyRepo(v)
    })
  }

  /** Open a file (from the Files panel) in this module's Code view and navigate to it. */
  private openFileInCode(path: string) {
    const idx = VIEWS.indexOf('code')
    this.mountView(idx)
    const code = this.instances['code'] as CodeEditorView | undefined
    code?.openFile(path)
    this.goTo(idx)
  }

  private createView(v: ViewType) {
    switch (v) {
      case 'code':     return new CodeEditorView()
      case 'files':    return new FileTreeView()
      case 'changes':  return new GitChangesView()
      case 'graph':    return new GitGraphView()
      case 'terminal': return new XTermView()
      case 'agent':    return new AgentView()
    }
  }

  connectTerminal(relay: RelaySocket, sessionId: string, label = 'Terminal') {
    this.mountView(VIEWS.indexOf('terminal'))
    this.xtermView?.connectSession(relay, sessionId, label)
  }

  /** Wire an opencode agent to this module's agent view. */
  connectAgent(relay: RelaySocket, agent: Agent) {
    this.mountView(VIEWS.indexOf('agent'))
    this.agentView?.connect(relay, agent)
    this.goTo(VIEWS.indexOf('agent'))
  }

  /** True if this module has an idle (unconnected) agent view slot. */
  hasIdleAgentView(): boolean {
    this.mountView(VIEWS.indexOf('agent'))
    return this.agentView?.idle ?? false
  }

  getAgentView(): AgentView | null  { return this.agentView }
  getTerminalView(): XTermView | null { return this.xtermView }
  fitTerminal() { this.xtermView?.fit() }

  private goTo(i: number) {
    if (i === this.viewIndex) return
    this.mountView(i)
    this.viewIndex = i
    this.trackEl.style.transform = `translateX(-${i * (100 / VIEWS.length)}%)`
    if (VIEWS[i] === 'terminal') setTimeout(() => this.xtermView?.fit(), 30)
    if (VIEWS[i] === 'agent')    setTimeout(() => this.agentView?.fit(),   30)
  }

  private bindGestures() {
    const width = () => this.contentEl.offsetWidth || 300
    let startIndex = 0, dragging = false

    this.cleanup = onLiveSwipe(
      this.contentEl,
      (dx) => {
        if (!dragging) { startIndex = this.viewIndex; dragging = true }
        const pct = 100 / VIEWS.length
        const offset = (startIndex * pct) - (dx / width() * 100 / VIEWS.length * VIEWS.length)
        const clamped = Math.max(0, Math.min((VIEWS.length - 1) * pct, offset))
        this.trackEl.style.transition = 'none'
        this.trackEl.style.transform = `translateX(-${clamped}%)`
        this.mountView(Math.max(0, Math.min(VIEWS.length - 1, Math.round(startIndex - dx / width() * VIEWS.length))))
      },
      (dx) => {
        dragging = false
        this.trackEl.style.transition = 'transform 0.28s cubic-bezier(0.25,0.46,0.45,0.94)'
        const threshold = width() * 0.28
        if (dx < -threshold && this.viewIndex < VIEWS.length - 1) this.goTo(this.viewIndex + 1)
        else if (dx > threshold && this.viewIndex > 0)            this.goTo(this.viewIndex - 1)
        else                                                       this.goTo(this.viewIndex)
      }
    )
  }

  destroy() {
    this.cleanup?.()
    this.xtermView?.destroy()
    this.agentView?.destroy()
  }

  getView(): ViewType { return VIEWS[this.viewIndex] }
}
