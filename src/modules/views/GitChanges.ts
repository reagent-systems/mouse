import type { Workspace, ChangedFile } from '../../runtime/Workspace.ts'

// Static fallback for demo/relay modes (no real workspace).
const FALLBACK_STAGED = [{ path: 'README.md', status: 'modified' as const, added: 9, removed: 2 }]
const FALLBACK_UNSTAGED = [
  { path: 'src/modules/Module.ts', status: 'modified' as const, added: 34, removed: 12 },
  { path: 'src/style.css', status: 'modified' as const, added: 18, removed: 4 },
  { path: 'src/app.ts', status: 'modified' as const, added: 8, removed: 0 },
]

/**
 * GitChangesView — shows the REAL change set from the on-device workspace
 * (files added/modified/deleted vs the last commit, with per-file line deltas)
 * and the Commit button folds those changes into a new baseline. Without a
 * workspace it shows the static sample (demo/relay modes).
 */
export class GitChangesView {
  el: HTMLElement
  private ws: Workspace | null

  constructor(workspace: Workspace | null = null) {
    this.ws = workspace
    this.el = document.createElement('div')
    this.el.className = 'view-changes'
    this.render()
    this.ws?.onChange(() => this.render())
  }

  private async render() {
    const changes: ChangedFile[] = this.ws
      ? await this.ws.changes()
      : [...FALLBACK_STAGED, ...FALLBACK_UNSTAGED]

    const count = changes.length
    const msg = this.ws ? this.suggestMessage(changes) : 'feat: add modular swipe panel system with glass UI'

    this.el.innerHTML = `
      <div class="changes-header">
        <span class="changes-label">CHANGES</span>
        <span class="changes-sparkle">✦</span>
      </div>
      <div class="commit-area">
        <div class="commit-msg">${esc(msg)}</div>
        <div class="commit-btn-row">
          <button class="commit-btn"${count ? '' : ' disabled'}>
            <span>✓</span> Commit${count ? ` (${count})` : ''}
          </button>
          <button class="commit-btn-drop">▾</button>
        </div>
      </div>
      <div class="changes-files-area">
        <div class="changes-section-hdr">
          <span>Changes</span>
          <span class="changes-count">${count}</span>
        </div>
        ${count ? changes.map(f => fileRow(f)).join('') : '<div class="files-empty">No changes</div>'}
      </div>
    `

    const btn = this.el.querySelector('.commit-btn') as HTMLButtonElement
    btn?.addEventListener('click', async () => {
      if (this.ws) {
        const n = await this.ws.commit()
        btn.innerHTML = `<span>✓</span> Committed ${n}`
        // render() re-runs via the workspace change event; reset label after.
        setTimeout(() => this.render(), 1200)
      } else {
        btn.textContent = '✓ Committed!'
        setTimeout(() => { btn.innerHTML = '<span>✓</span> Commit' }, 1500)
      }
    })
  }

  /** Heuristic commit message from the change set. */
  private suggestMessage(changes: ChangedFile[]): string {
    if (!changes.length) return 'No changes to commit'
    if (changes.length === 1) {
      const f = changes[0]
      const verb = f.status === 'added' ? 'add' : f.status === 'deleted' ? 'remove' : 'update'
      return `${verb} ${f.path.split('/').pop()}`
    }
    return `update ${changes.length} files`
  }
}

function fileRow(f: ChangedFile) {
  const color = f.status === 'added' ? 'var(--green)' : f.status === 'deleted' ? 'var(--red)' : 'var(--blue)'
  return `
    <div class="changed-file">
      <div class="changed-file-name">
        <span style="color:${color}">◆</span>
        <span>${esc(f.path.split('/').pop() ?? f.path)}</span>
      </div>
      <div class="changed-file-stats">
        <span class="stat-add">+${f.added}</span>
        <span style="color:var(--text-faint)">, </span>
        <span class="stat-del">-${f.removed}</span>
      </div>
    </div>
  `
}

function esc(s: string): string {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
}
