import { Terminal } from '@xterm/xterm'
import { FitAddon } from '@xterm/addon-fit'
import { WebLinksAddon } from '@xterm/addon-web-links'
import { PyodideRunner, installInputBridge } from '../../runtime/PyodideRunner.ts'
import { BUNDLES, withTask } from '../../runtime/bundles.ts'
import type { ScriptBundle } from '../../runtime/bundles.ts'
import '@xterm/xterm/css/xterm.css'

/**
 * ScriptTerminalView — a terminal-LOOKING panel that is actually an in-app
 * Python script runner (Pyodide). It renders through a real xterm.js widget, so
 * it genuinely is a terminal surface; we just feed it our script's stdout
 * instead of a PTY. No server, no relay, runs on the phone.
 *
 * Top: a launcher strip of prepackaged bundles (Run agent / Python REPL / HTTP).
 * Bottom: an input row that doubles as the answer to a Python input() prompt.
 */
export class ScriptTerminalView {
  el: HTMLElement
  private term: Terminal
  private fitAddon: FitAddon
  private termContainer: HTMLElement
  private launcher: HTMLElement
  private inputRow: HTMLElement
  private inputEl: HTMLInputElement
  private resizeObserver: ResizeObserver

  private runner = new PyodideRunner()
  private pushAnswer: ((a: string) => void) | null = null
  private running = false
  private awaitingInput = false

  constructor() {
    this.el = document.createElement('div')
    this.el.className = 'view-scriptterm'

    // ── Launcher strip ──
    this.launcher = document.createElement('div')
    this.launcher.className = 'scriptterm-launcher'
    BUNDLES.forEach((b) => this.launcher.appendChild(this.makeBundleChip(b)))

    // ── Terminal canvas ──
    this.termContainer = document.createElement('div')
    this.termContainer.className = 'scriptterm-canvas'

    // ── Input row (also answers input() prompts) ──
    this.inputRow = document.createElement('div')
    this.inputRow.className = 'scriptterm-input-row'
    const label = document.createElement('span')
    label.className = 't-prompt-label'
    label.textContent = '>'
    this.inputEl = document.createElement('input')
    this.inputEl.className = 'scriptterm-input'
    this.inputEl.placeholder = 'Run a bundle above, or type an answer…'
    this.inputEl.addEventListener('keydown', (e) => {
      if (e.key === 'Enter') this.submitInput()
    })
    this.inputRow.appendChild(label)
    this.inputRow.appendChild(this.inputEl)

    this.el.appendChild(this.launcher)
    this.el.appendChild(this.termContainer)
    this.el.appendChild(this.inputRow)

    this.term = new Terminal({
      theme: {
        background: '#0c0c14', foreground: '#d4d4d4', cursor: '#a855f7',
        green: '#4ade80', yellow: '#fbbf24', blue: '#60a5fa',
        magenta: '#a855f7', cyan: '#22d3ee', red: '#f87171',
      },
      fontFamily: '"SF Mono","Fira Code",ui-monospace,monospace',
      fontSize: 12, lineHeight: 1.5,
      cursorBlink: true, cursorStyle: 'bar',
      scrollback: 3000, allowTransparency: true, convertEol: true,
    })
    this.fitAddon = new FitAddon()
    this.term.loadAddon(this.fitAddon)
    this.term.loadAddon(new WebLinksAddon())
    this.resizeObserver = new ResizeObserver(() => this.fit())
  }

  mount() {
    requestAnimationFrame(() => {
      this.term.open(this.termContainer)
      this.fitAddon.fit()
      this.resizeObserver.observe(this.el)
      this.write('\x1b[2m  In-app Python runtime. Tap a bundle to run.\x1b[0m\r\n')
    })
  }

  /** Public entry: run an agent for a composer task (used by the app). */
  runTask(task: string) {
    this.runBundle(BUNDLES[0], task)
  }

  private makeBundleChip(b: ScriptBundle): HTMLElement {
    const chip = document.createElement('button')
    chip.className = 'scriptterm-chip'
    chip.innerHTML = `<span class="scriptterm-chip-icon">${b.icon}</span><span>${b.title}</span>`
    chip.title = b.subtitle
    chip.addEventListener('click', () => this.runBundle(b, ''))
    return chip
  }

  private async runBundle(b: ScriptBundle, task: string) {
    if (this.running) { this.write('\x1b[33m(busy — wait for the current run)\x1b[0m\r\n'); return }
    this.running = true
    this.term.clear()
    this.write(`\x1b[2m$ run ${b.id}\x1b[0m\r\n`)

    try {
      // Ensure runtime + input bridge are ready.
      await this.runner.warmup((s) => this.write(`\x1b[2m${s}\x1b[0m\r\n`))
      const py = (this.runner as any).py
      this.pushAnswer = await installInputBridge(py, (prompt) => {
        this.awaitingInput = true
        if (prompt) this.write(prompt)
        this.inputEl.focus()
      })

      const code = withTask(b.code, task)
      const handle = this.runner.run(
        code,
        (chunk) => this.write(chunk.replace(/\n/g, '\r\n')),
        (chunk) => this.write(chunk.replace(/\n/g, '\r\n')),
      )
      await handle.done.catch(() => { /* error already streamed */ })
    } finally {
      this.running = false
      this.awaitingInput = false
      this.write('\x1b[2m\r\n[done]\x1b[0m\r\n')
    }
  }

  private submitInput() {
    const v = this.inputEl.value
    this.inputEl.value = ''
    if (this.awaitingInput && this.pushAnswer) {
      this.write(v + '\r\n')
      this.awaitingInput = false
      this.pushAnswer(v)
    }
  }

  private write(s: string) { this.term.write(s) }

  fit() {
    try { this.fitAddon.fit() } catch { /* ignore */ }
  }

  destroy() {
    this.resizeObserver.disconnect()
    this.term.dispose()
  }
}
