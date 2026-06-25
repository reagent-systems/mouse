import type { Workspace } from '../../runtime/Workspace.ts'

type FlatNode = { name: string; path: string; depth: number; isDir: boolean }

const ICONS: Record<string, { icon: string; cls: string }> = {
  ts:   { icon: '◆', cls: 'fi-ts' },
  js:   { icon: '◆', cls: 'fi-ts' },
  py:   { icon: '◆', cls: 'fi-ts' },
  json: { icon: '◆', cls: 'fi-json' },
  md:   { icon: '◆', cls: 'fi-md' },
  css:  { icon: '◆', cls: 'fi-css' },
  env:  { icon: '◆', cls: 'fi-env' },
}

function iconFor(name: string): { icon: string; cls: string } {
  const ext = name.includes('.') ? name.split('.').pop()! : ''
  return ICONS[ext] ?? { icon: '◆', cls: 'fi-ts' }
}

/** Build a flat, indented tree from a list of file paths. */
function buildTree(paths: string[]): FlatNode[] {
  const dirs = new Set<string>()
  for (const p of paths) {
    const parts = p.split('/')
    for (let i = 1; i < parts.length; i++) dirs.add(parts.slice(0, i).join('/'))
  }
  const all = new Set<string>([...dirs, ...paths])
  return [...all].sort().map((full) => {
    const parts = full.split('/')
    return {
      name: parts[parts.length - 1],
      path: full,
      depth: parts.length - 1,
      isDir: dirs.has(full),
    }
  })
}

/**
 * FileTreeView — renders the REAL files in the on-device workspace. Tapping a
 * file asks the workspace's listeners (via onSelect) to open it in the editor.
 * Without a workspace it shows nothing (no fake tree).
 */
export class FileTreeView {
  el: HTMLElement
  private ws: Workspace | null
  private selected: HTMLElement | null = null
  private onSelectFn: ((path: string) => void) | null = null

  constructor(workspace: Workspace | null = null) {
    this.ws = workspace
    this.el = document.createElement('div')
    this.el.className = 'view-files'
    this.render()
    this.ws?.onChange(() => this.render())
  }

  onSelect(fn: (path: string) => void) { this.onSelectFn = fn }

  private async render() {
    if (!this.ws) {
      this.el.innerHTML = `<div class="files-empty">No workspace</div>`
      return
    }
    const paths = await this.ws.listFiles()
    if (!paths.length) {
      this.el.innerHTML = `<div class="files-empty">No files</div>`
      return
    }
    this.el.innerHTML = ''
    for (const node of buildTree(paths)) {
      const item = document.createElement('div')
      const indentCls = node.depth > 0 ? `ind${Math.min(node.depth, 3)}` : ''
      item.className = `file-item ${indentCls}`
      if (node.isDir) {
        item.innerHTML = `<span class="fi fi-dir">▶</span><span>${esc(node.name)}</span>`
      } else {
        const { icon, cls } = iconFor(node.name)
        item.innerHTML = `<span class="fi ${cls}">${icon}</span><span>${esc(node.name)}</span>`
        item.addEventListener('click', () => {
          if (this.selected) this.selected.classList.remove('selected')
          item.classList.add('selected')
          this.selected = item
          this.onSelectFn?.(node.path)
        })
      }
      this.el.appendChild(item)
    }
  }
}

function esc(s: string): string {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
}
