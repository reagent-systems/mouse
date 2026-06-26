import { Terminal } from '@xterm/xterm'
import { FitAddon } from '@xterm/addon-fit'
import { WebLinksAddon } from '@xterm/addon-web-links'
import type { IRelay } from './RelaySocket.ts'
import '@xterm/xterm/css/xterm.css'

interface SessionState {
  label: string
  scrollback: string   // raw data buffered while session is inactive
}

export class XTermView {
  el: HTMLElement
  private term: Terminal
  private fitAddon: FitAddon
  private tabBar: HTMLElement
  private termContainer: HTMLElement
  private mobileInput: HTMLInputElement
  private resizeObserver: ResizeObserver

  private relay: IRelay | null = null
  private activeId: string | null = null
  private sessions = new Map<string, SessionState>()
  private unsubs: (() => void)[] = []

  constructor() {
    this.el = document.createElement('div')
    this.el.className = 'xterm-wrap'
    this.el.style.cssText = 'height:100%;width:100%;display:flex;flex-direction:column;background:#0c0c14;'

    // Tab bar
    this.tabBar = document.createElement('div')
    this.tabBar.className = 'xterm-tabs'
    this.tabBar.style.display = 'none'

    // Terminal canvas container
    this.termContainer = document.createElement('div')
    this.termContainer.style.cssText = 'flex:1;min-height:0;padding:4px 2px;box-sizing:border-box;'

    // Mobile keyboard input overlay
    this.mobileInput = document.createElement('input')
    this.mobileInput.type = 'text'
    this.mobileInput.autocomplete = 'off'
    this.mobileInput.autocapitalize = 'off'
    this.mobileInput.style.cssText = 'position:absolute;opacity:0;width:1px;height:1px;bottom:0;left:0;pointer-events:none;z-index:100;'
    this.mobileInput.addEventListener('input', (e) => {
      const v = (e as InputEvent).data ?? ''
      if (v && this.relay && this.activeId) {
        this.relay.sendInput(this.activeId, v)
        this.mobileInput.value = ''
      }
    })
    this.mobileInput.addEventListener('keydown', (e) => {
      if (!this.relay || !this.activeId) return
      if (e.key === 'Enter')     { this.relay.sendInput(this.activeId, '\r');    this.mobileInput.value = ''; e.preventDefault() }
      else if (e.key === 'Backspace') { this.relay.sendInput(this.activeId, '\x7f'); e.preventDefault() }
    })

    this.el.addEventListener('click', () => {
      if ('ontouchstart' in window) this.mobileInput.focus()
    })

    this.el.appendChild(this.tabBar)
    this.el.appendChild(this.termContainer)
    this.el.appendChild(this.mobileInput)

    this.term = new Terminal({
      theme: {
        background: '#0c0c14', foreground: '#d4d4d4', cursor: '#a855f7',
        black: '#1e1e2e',    red: '#f87171',   green: '#4ade80',  yellow: '#fbbf24',
        blue: '#60a5fa',     magenta: '#a855f7', cyan: '#22d3ee', white: '#d4d4d4',
        brightBlack: '#4a4a5a', brightRed: '#ff8fa3', brightGreen: '#a3e635',
        brightYellow: '#fde68a', brightBlue: '#93c5fd', brightMagenta: '#c4b5fd',
        brightCyan: '#67e8f9', brightWhite: '#f8fafc',
      },
      fontFamily: '"SF Mono","Fira Code",ui-monospace,monospace',
      fontSize: 12, lineHeight: 1.5,
      cursorBlink: true, cursorStyle: 'bar',
      scrollback: 3000, allowTransparency: true,
    })

    this.fitAddon = new FitAddon()
    this.term.loadAddon(this.fitAddon)
    this.term.loadAddon(new WebLinksAddon())

    this.term.onData(data => {
      if (this.relay && this.activeId) this.relay.sendInput(this.activeId, data)
    })

    this.resizeObserver = new ResizeObserver(() => this.fit())
  }

  mount() {
    requestAnimationFrame(() => {
      this.term.open(this.termContainer)
      this.fitAddon.fit()
      this.resizeObserver.observe(this.el)
      this.term.write('\x1b[2m  Waiting for Codespace…\x1b[0m\r\n')
    })
  }

  // ── Session management ──────────────────────────────

  addSession(relay: IRelay, id: string, label: string) {
    this.relay = relay
    if (this.sessions.has(id)) return

    this.sessions.set(id, { label, scrollback: '' })
    this.renderTabs()

    // Subscribe to output
    const unsub = relay.onSessionData(id, (data) => {
      if (this.activeId === id) {
        this.term.write(data)
      } else {
        // Buffer for later
        const s = this.sessions.get(id)!
        s.scrollback += data
      }
    })
    this.unsubs.push(unsub)

    // Subscribe to exit — dim the tab
    relay.onSessionExit(id, () => {
      const s = this.sessions.get(id)
      if (s) { s.label += ' (done)'; this.renderTabs() }
    })

    // Auto-switch to first session
    if (!this.activeId) this.switchSession(id)
  }

  removeSession(id: string) {
    this.sessions.delete(id)
    if (this.activeId === id) {
      const first = this.sessions.keys().next().value
      if (first) this.switchSession(first)
      else this.activeId = null
    }
    this.renderTabs()
  }

  switchSession(id: string) {
    if (!this.sessions.has(id)) return
    this.activeId = id
    this.term.clear()
    const s = this.sessions.get(id)!
    if (s.scrollback) {
      this.term.write(s.scrollback)
      s.scrollback = ''
    }
    this.renderTabs()
    this.fit()
  }

  // ── Legacy single-session connect (used by Module) ──
  connectSession(relay: IRelay, sessionId: string, label = 'Terminal') {
    this.addSession(relay, sessionId, label)
  }

  fit() {
    try {
      this.fitAddon.fit()
      if (this.relay && this.activeId) {
        this.relay.resize(this.activeId, this.term.cols, this.term.rows)
      }
    } catch {}
  }

  // ── Tab bar ─────────────────────────────────────────

  private renderTabs() {
    if (this.sessions.size <= 1) {
      this.tabBar.style.display = 'none'
      return
    }
    this.tabBar.style.display = 'flex'
    this.tabBar.innerHTML = ''
    for (const [id, s] of this.sessions) {
      const tab = document.createElement('div')
      tab.className = `xterm-tab${id === this.activeId ? ' active' : ''}`
      tab.textContent = s.label
      tab.addEventListener('click', () => this.switchSession(id))
      this.tabBar.appendChild(tab)
    }
  }

  destroy() {
    this.unsubs.forEach(fn => fn())
    this.resizeObserver.disconnect()
    this.term.dispose()
  }
}
