import { onLiveSwipe } from '../gestures/index.ts'
import { CodeEditorView } from './views/CodeEditor.ts'
import { FileTreeView } from './views/FileTree.ts'
import { GitChangesView } from './views/GitChanges.ts'
import { GitGraphView } from './views/GitGraph.ts'
import { AgentView } from './views/AgentView.ts'
import { ScriptTerminalView } from './views/ScriptTerminal.ts'
import { XTermView } from '../terminal/XTermView.ts'
import type { IRelay } from '../terminal/RelaySocket.ts'
import type { Agent } from '../agents/Agent.ts'
import type { Workspace } from '../runtime/Workspace.ts'

export type ViewType = 'code' | 'files' | 'changes' | 'graph' | 'script' | 'terminal' | 'agent'
const VIEWS: ViewType[] = ['code', 'files', 'changes', 'graph', 'script', 'terminal', 'agent']

export class Module {
  el: HTMLElement
  private contentEl: HTMLElement
  private trackEl: HTMLElement
  private viewIndex: number
  private instances: Partial<Record<ViewType, { el: HTMLElement }>> = {}
  private xtermView: XTermView | null = null
  private agentView: AgentView | null = null
  private scriptView: ScriptTerminalView | null = null
  private cleanup: (() => void) | null = null
  private workspace: Workspace | null

  constructor(initialView: ViewType = 'code', workspace: Workspace | null = null) {
    this.viewIndex = VIEWS.indexOf(initialView)
    this.workspace = workspace

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
    if (v === 'script' && view instanceof ScriptTerminalView) {
      this.scriptView = view
      view.mount()
    }
    if (v === 'agent' && view instanceof AgentView) {
      this.agentView = view
      view.mount()
    }
  }

  private createView(v: ViewType) {
    switch (v) {
      case 'code':     return new CodeEditorView(this.workspace)
      case 'files':    return new FileTreeView(this.workspace)
      case 'changes':  return new GitChangesView(this.workspace)
      case 'graph':    return new GitGraphView()
      case 'script':   return new ScriptTerminalView()
      case 'terminal': return new XTermView()
      case 'agent':    return new AgentView()
    }
  }

  /** Run an agent task as an in-app Python script (no relay/PTY needed). */
  runScriptTask(task: string) {
    this.mountView(VIEWS.indexOf('script'))
    this.scriptView?.runTask(task)
    this.goTo(VIEWS.indexOf('script'))
  }

  /** Wire this module's file tree to its code editor: tap a file → open it. */
  linkFileTreeToEditor() {
    this.mountView(VIEWS.indexOf('files'))
    this.mountView(VIEWS.indexOf('code'))
    const tree = this.instances['files'] as FileTreeView | undefined
    const editor = this.instances['code'] as CodeEditorView | undefined
    if (tree && editor) {
      tree.onSelect((path) => {
        editor.setFile(path)
        this.goTo(VIEWS.indexOf('code'))
      })
    }
  }

  connectTerminal(relay: IRelay, sessionId: string, label = 'Terminal') {
    this.mountView(VIEWS.indexOf('terminal'))
    this.xtermView?.connectSession(relay, sessionId, label)
  }

  /** Wire an opencode agent to this module's agent view. */
  connectAgent(relay: IRelay, agent: Agent) {
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
    if (VIEWS[i] === 'script')   setTimeout(() => this.scriptView?.fit(),  30)
    if (VIEWS[i] === 'agent')    setTimeout(() => this.agentView?.fit(),   30)
  }

  /** Public navigation by view name — mounts the view and slides to it. */
  showView(v: ViewType) {
    const i = VIEWS.indexOf(v)
    if (i >= 0) this.goTo(i)
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
    this.scriptView?.destroy()
    this.agentView?.destroy()
  }

  getView(): ViewType { return VIEWS[this.viewIndex] }
}
