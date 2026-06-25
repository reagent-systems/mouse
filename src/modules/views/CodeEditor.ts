import type { Workspace } from '../../runtime/Workspace.ts'

const FALLBACK_SOURCE = `<p align="center">
  <img src="assets/mouse-logo.png" alt="Mouse" />
</p>

<p align="center">
  A mobile-first coding agent platform built
  around a modular, liquid-glass GUI system.
</p>

## Features

- Modular resizable panels (swipe to change)
- Multi-agent parallel execution
- Git changes, graph, and one-tap commit`

function esc(s: string) {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
}

/**
 * Tokenizing HTML/markdown/code highlighter. Builds spans from the RAW source so
 * it never re-matches its own injected markup. Each fragment is escaped once.
 */
function highlightLine(raw: string): string {
  if (raw.trim() === '') return '&nbsp;'
  if (/^#{1,6}\s/.test(raw)) return `<span class="fn">${esc(raw)}</span>`
  if (/^\s*#/.test(raw)) return `<span class="cmt">${esc(raw)}</span>`   // py/sh comment

  if (/^\s*<\/?[a-zA-Z]/.test(raw)) {
    let out = ''
    let i = 0
    while (i < raw.length) {
      const rest = raw.slice(i)
      let m = rest.match(/^<\/?[a-zA-Z][\w-]*/)
      if (m) { out += `<span class="tag">${esc(m[0])}</span>`; i += m[0].length; continue }
      m = rest.match(/^\/?>/)
      if (m) { out += `<span class="tag">${esc(m[0])}</span>`; i += m[0].length; continue }
      m = rest.match(/^[a-zA-Z_:][\w:-]*(?==)/)
      if (m) { out += `<span class="attr">${esc(m[0])}</span>`; i += m[0].length; continue }
      m = rest.match(/^"[^"]*"/)
      if (m) { out += `<span class="str">${esc(m[0])}</span>`; i += m[0].length; continue }
      out += esc(raw[i]); i++
    }
    return out
  }

  const e = esc(raw)
  return e
    .replace(/\b(def|class|import|from|return|async|await|if|else|for|while|const|let|function|export)\b/g, '<span class="kw">$1</span>')
    .replace(/(&quot;[^&]*&quot;|'[^']*'|"[^"]*")/g, '<span class="str">$1</span>')
    .replace(/\*\*([^*]+)\*\*/g, '<span class="kw">$1</span>')
}

/**
 * CodeEditorView — shows and EDITS a real file from the on-device workspace.
 * Read mode renders highlighted lines; tapping "Edit" swaps to a textarea that
 * writes back to the workspace (which then recomputes changes). Without a
 * workspace it shows the static README sample (demo/relay modes).
 */
export class CodeEditorView {
  el: HTMLElement
  private ws: Workspace | null
  private scroll!: HTMLElement
  private header!: HTMLElement
  private editor!: HTMLTextAreaElement
  private editing = false
  private path = ''

  constructor(workspace: Workspace | null = null) {
    this.ws = workspace
    this.el = document.createElement('div')
    this.el.className = 'view-code'
    this.build()
    if (this.ws) this.openFirstFile()
    else this.renderStatic()
  }

  /** Open a specific file (called by the file tree). */
  async setFile(path: string) {
    if (!this.ws) return
    this.path = path
    const content = await this.ws.read(path)
    this.renderContent(path, content)
  }

  private build() {
    this.header = document.createElement('div')
    this.header.className = 'code-file-header'

    this.scroll = document.createElement('div')
    this.scroll.className = 'code-scroll'

    this.editor = document.createElement('textarea')
    this.editor.className = 'code-editor-area'
    this.editor.spellcheck = false
    this.editor.style.display = 'none'
    this.editor.addEventListener('input', () => this.saveDebounced())

    this.el.appendChild(this.header)
    this.el.appendChild(this.scroll)
    this.el.appendChild(this.editor)
  }

  private async openFirstFile() {
    const files = await this.ws!.listFiles()
    const pick = files.find(f => /readme/i.test(f)) ?? files[0]
    if (pick) this.setFile(pick)
    else this.renderContent('', '')
  }

  private renderContent(path: string, content: string) {
    this.path = path
    this.header.innerHTML = `
      <span style="color:var(--blue)">ℹ</span>
      <span>${esc(path || 'untitled')}</span>
      <button type="button" class="code-edit-btn" id="edit-toggle">${this.editing ? 'Done' : 'Edit'}</button>
    `
    this.header.querySelector('#edit-toggle')!.addEventListener('click', () => this.toggleEdit(content))

    if (this.editing) {
      this.scroll.style.display = 'none'
      this.editor.style.display = 'block'
      this.editor.value = content
    } else {
      this.editor.style.display = 'none'
      this.scroll.style.display = 'block'
      this.scroll.innerHTML = ''
      for (const line of content.split('\n')) {
        const div = document.createElement('div')
        div.className = 'code-line'
        div.innerHTML = highlightLine(line) || '&nbsp;'
        this.scroll.appendChild(div)
      }
    }
  }

  private toggleEdit(content: string) {
    this.editing = !this.editing
    const current = this.editing ? content : this.editor.value
    this.renderContent(this.path, this.editing ? content : current)
  }

  private saveTimer: ReturnType<typeof setTimeout> | null = null
  private saveDebounced() {
    if (!this.ws || !this.path) return
    if (this.saveTimer) clearTimeout(this.saveTimer)
    this.saveTimer = setTimeout(() => {
      this.ws!.write(this.path, this.editor.value)
    }, 300)
  }

  private renderStatic() {
    this.header.innerHTML = `
      <span style="color:var(--blue)">ℹ</span>
      <span>README.md</span>
    `
    this.scroll.innerHTML = ''
    for (const line of FALLBACK_SOURCE.split('\n')) {
      const div = document.createElement('div')
      div.className = 'code-line'
      div.innerHTML = highlightLine(line) || '&nbsp;'
      this.scroll.appendChild(div)
    }
    const footer = document.createElement('div')
    footer.className = 'code-link-hint'
    footer.innerHTML = `
      <span class="code-link-hint-icon" aria-hidden="true">↗</span>
      <span class="code-link-hint-text">Follow link <span class="code-link-hint-kbd">(cmd + click)</span></span>
    `
    this.el.appendChild(footer)
  }
}
