import type { RepoService } from '../../codespaces/RepoService.ts'

const DEFAULT_FILES = ['README.md', 'readme.md', 'README', 'package.json']
const KEYWORDS = new Set([
  'const', 'let', 'var', 'function', 'return', 'if', 'else', 'for', 'while', 'class',
  'extends', 'import', 'export', 'from', 'default', 'new', 'await', 'async', 'try',
  'catch', 'finally', 'throw', 'typeof', 'instanceof', 'in', 'of', 'this', 'super',
  'public', 'private', 'protected', 'static', 'interface', 'type', 'enum', 'void',
  'true', 'false', 'null', 'undefined', 'def', 'self', 'lambda', 'with', 'as', 'pass',
])

function esc(s: string): string {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
}

/** Light, language-agnostic highlighter operating on already-escaped text. */
function highlight(raw: string): string {
  const e = esc(raw)
  const tokens: string[] = []
  const stash = (html: string) => `\u0000${tokens.push(html) - 1}\u0000`

  let s = e
  // Comments to end of line (// or #).
  s = s.replace(/(\/\/|#).*/g, m => stash(`<span class="cmt">${m}</span>`))
  // Strings (single, double, backtick) — escaped quotes already turned into entities.
  s = s.replace(/(&quot;[^&]*?&quot;|&#39;[^&]*?&#39;|'[^']*?'|"[^"]*?"|`[^`]*?`)/g,
    m => stash(`<span class="str">${m}</span>`))
  // Numbers.
  s = s.replace(/\b(\d[\d_.]*)\b/g, m => stash(`<span class="num">${m}</span>`))
  // Keywords.
  s = s.replace(/\b([A-Za-z_]\w*)\b/g, (m) => (KEYWORDS.has(m) ? stash(`<span class="kw">${m}</span>`) : m))

  return s.replace(/\u0000(\d+)\u0000/g, (_, i) => tokens[Number(i)])
}

export class CodeEditorView {
  el: HTMLElement
  private repo: RepoService | null = null
  private hdr: HTMLElement
  private scroll: HTMLElement
  private currentPath: string | null = null

  constructor() {
    this.el = document.createElement('div')
    this.el.className = 'view-code'

    this.hdr = document.createElement('div')
    this.hdr.className = 'code-file-header'
    this.hdr.innerHTML = `<span style="color:var(--blue)">ℹ</span><span>Code</span>`

    this.scroll = document.createElement('div')
    this.scroll.className = 'code-scroll'
    this.scroll.innerHTML = `<div class="panel-msg">Connect a Codespace to browse files.</div>`

    this.el.appendChild(this.hdr)
    this.el.appendChild(this.scroll)
  }

  connectRepo(repo: RepoService) {
    this.repo = repo
    if (!this.currentPath) this.openDefault()
  }

  async openFile(path: string) {
    if (!this.repo) return
    this.currentPath = path
    this.setHeader(path)
    this.scroll.innerHTML = `<div class="panel-msg">Loading ${esc(path)}…</div>`
    try {
      const content = await this.repo.readFile(path)
      this.renderContent(content)
    } catch (e) {
      this.scroll.innerHTML = `<div class="panel-msg panel-error">${esc(errMsg(e))}</div>`
    }
  }

  private async openDefault() {
    if (!this.repo) return
    for (const name of DEFAULT_FILES) {
      try {
        const content = await this.repo.readFile(name)
        this.currentPath = name
        this.setHeader(name)
        this.renderContent(content)
        return
      } catch {
        /* try next */
      }
    }
    this.scroll.innerHTML = `<div class="panel-msg">Select a file from the Files panel.</div>`
  }

  private setHeader(path: string) {
    const name = path.split('/').pop() ?? path
    this.hdr.innerHTML = `<span style="color:var(--blue)">ℹ</span><span>${esc(name)}</span>` +
      `<span style="color:var(--text-faint);margin-left:auto;font-size:10px">${esc(path)}</span>`
  }

  private renderContent(content: string) {
    const lines = content.replace(/\n$/, '').split('\n')
    const gutterW = String(lines.length).length
    this.scroll.innerHTML = ''
    lines.forEach((line, i) => {
      const div = document.createElement('div')
      div.className = 'code-line'
      const num = String(i + 1).padStart(gutterW, ' ')
      div.innerHTML = `<span class="code-gutter">${num}</span>${highlight(line) || '&nbsp;'}`
      this.scroll.appendChild(div)
    })
    this.scroll.scrollTop = 0
  }
}

function errMsg(e: unknown): string {
  return e instanceof Error ? e.message : String(e)
}
