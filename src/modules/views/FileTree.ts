import type { RepoService } from '../../codespaces/RepoService.ts'

interface DirNode {
  name: string
  dirs: Map<string, DirNode>
  files: string[]
}

function newDir(name: string): DirNode {
  return { name, dirs: new Map(), files: [] }
}

function esc(s: string): string {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
}

const EXT_CLASS: Record<string, string> = {
  ts: 'fi-ts', tsx: 'fi-ts', js: 'fi-ts', jsx: 'fi-ts', mjs: 'fi-ts', cjs: 'fi-ts',
  json: 'fi-json', md: 'fi-md', css: 'fi-css', scss: 'fi-css',
  gitignore: 'fi-git', env: 'fi-env', example: 'fi-env',
}

function fileClass(name: string): string {
  const dot = name.lastIndexOf('.')
  const ext = dot === -1 ? name.replace(/^\./, '') : name.slice(dot + 1)
  return EXT_CLASS[ext.toLowerCase()] ?? 'fi-ts'
}

export class FileTreeView {
  el: HTMLElement
  private repo: RepoService | null = null
  private onOpen: ((path: string) => void) | null = null
  private selectedEl: HTMLElement | null = null

  constructor() {
    this.el = document.createElement('div')
    this.el.className = 'view-files'
    this.el.innerHTML = `<div class="panel-msg">Connect a Codespace to browse files.</div>`
  }

  /** Register a handler invoked when the user taps a file. */
  onOpenFile(cb: (path: string) => void) {
    this.onOpen = cb
  }

  connectRepo(repo: RepoService) {
    this.repo = repo
    this.refresh()
  }

  async refresh() {
    if (!this.repo) return
    this.el.innerHTML = `<div class="panel-msg">Loading files…</div>`
    try {
      const files = await this.repo.listFiles()
      if (files.length === 0) {
        this.el.innerHTML = `<div class="panel-msg">No files in this repository.</div>`
        return
      }
      const root = newDir('')
      for (const path of files) this.insert(root, path)
      this.el.innerHTML = ''
      this.renderDir(root, '', 0, this.el)
    } catch (e) {
      this.el.innerHTML = `<div class="panel-msg panel-error">${esc(errMsg(e))}</div>`
    }
  }

  private insert(root: DirNode, path: string) {
    const parts = path.split('/')
    let node = root
    for (let i = 0; i < parts.length - 1; i++) {
      const seg = parts[i]
      if (!node.dirs.has(seg)) node.dirs.set(seg, newDir(seg))
      node = node.dirs.get(seg)!
    }
    node.files.push(parts[parts.length - 1])
  }

  private renderDir(node: DirNode, prefix: string, depth: number, parent: HTMLElement) {
    const dirNames = [...node.dirs.keys()].sort((a, b) => a.localeCompare(b))
    for (const name of dirNames) {
      const child = node.dirs.get(name)!
      const fullPath = prefix ? `${prefix}/${name}` : name

      const row = document.createElement('div')
      row.className = 'file-item'
      row.style.paddingLeft = `${14 + depth * 14}px`
      const caret = document.createElement('span')
      caret.className = 'fi fi-dir fi-caret'
      caret.textContent = '▸'
      const label = document.createElement('span')
      label.textContent = name
      row.appendChild(caret)
      row.appendChild(label)

      const childWrap = document.createElement('div')
      childWrap.hidden = true
      this.renderDir(child, fullPath, depth + 1, childWrap)

      let open = false
      row.addEventListener('click', () => {
        open = !open
        childWrap.hidden = !open
        caret.textContent = open ? '▾' : '▸'
      })

      parent.appendChild(row)
      parent.appendChild(childWrap)
    }

    const files = [...node.files].sort((a, b) => a.localeCompare(b))
    for (const name of files) {
      const fullPath = prefix ? `${prefix}/${name}` : name
      const row = document.createElement('div')
      row.className = 'file-item'
      row.style.paddingLeft = `${14 + depth * 14}px`
      row.innerHTML = `<span class="fi ${fileClass(name)}">◆</span><span>${esc(name)}</span>`
      row.addEventListener('click', () => {
        if (this.selectedEl) this.selectedEl.classList.remove('selected')
        row.classList.add('selected')
        this.selectedEl = row
        this.onOpen?.(fullPath)
      })
      parent.appendChild(row)
    }
  }
}

function errMsg(e: unknown): string {
  return e instanceof Error ? e.message : String(e)
}
