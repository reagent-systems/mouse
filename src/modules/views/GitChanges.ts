import type { RepoService, GitFileChange, GitStatus } from '../../codespaces/RepoService.ts'

function esc(s: string): string {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
}

export class GitChangesView {
  el: HTMLElement
  private repo: RepoService | null = null
  private status: GitStatus | null = null
  private busy = false

  constructor() {
    this.el = document.createElement('div')
    this.el.className = 'view-changes'
    this.el.innerHTML = `<div class="panel-msg">Connect a Codespace to see changes.</div>`
  }

  connectRepo(repo: RepoService) {
    this.repo = repo
    this.refresh()
  }

  async refresh() {
    if (!this.repo) return
    try {
      this.status = await this.repo.status()
      this.render()
    } catch (e) {
      this.el.innerHTML = `<div class="panel-msg panel-error">${esc(errMsg(e))}</div>`
    }
  }

  private render() {
    const st = this.status
    if (!st) return
    const total = st.staged.length + st.unstaged.length

    this.el.innerHTML = `
      <div class="changes-header">
        <span class="changes-label">CHANGES${st.branch ? ` · ${esc(st.branch)}` : ''}</span>
        <span class="changes-sparkle" id="refresh-btn" title="Refresh">↻</span>
      </div>
      <div class="commit-area">
        <textarea class="commit-input" id="commit-msg" rows="1" placeholder="Commit message"></textarea>
        <div class="commit-btn-row">
          <button class="commit-btn" id="commit-btn" ${st.staged.length === 0 ? 'disabled' : ''}>
            <span>✓</span> Commit${st.staged.length ? ` (${st.staged.length})` : ''}
          </button>
        </div>
      </div>
      <div class="changes-files-area">
        ${section('Staged', st.staged, 'staged')}
        ${section('Changes', st.unstaged, 'unstaged')}
        ${total === 0 ? `<div class="panel-msg">Working tree clean.</div>` : ''}
      </div>
    `

    this.el.querySelector('#refresh-btn')?.addEventListener('click', () => this.refresh())

    this.el.querySelectorAll<HTMLElement>('.changed-file').forEach(row => {
      row.addEventListener('click', () => this.toggleStage(row.dataset.path!, row.dataset.group === 'staged'))
    })

    const commitBtn = this.el.querySelector('#commit-btn') as HTMLButtonElement | null
    commitBtn?.addEventListener('click', () => this.commit())
  }

  private async toggleStage(path: string, staged: boolean) {
    if (!this.repo || this.busy) return
    this.busy = true
    try {
      if (staged) await this.repo.unstage(path)
      else await this.repo.stage(path)
      await this.refresh()
    } catch (e) {
      this.flash(errMsg(e))
    } finally {
      this.busy = false
    }
  }

  private async commit() {
    if (!this.repo || this.busy) return
    const input = this.el.querySelector('#commit-msg') as HTMLTextAreaElement | null
    const msg = input?.value.trim()
    if (!msg) {
      input?.focus()
      return
    }
    const btn = this.el.querySelector('#commit-btn') as HTMLButtonElement | null
    this.busy = true
    if (btn) { btn.disabled = true; btn.textContent = 'Committing…' }
    try {
      const short = await this.repo.commit(msg)
      this.flash(`Committed ${short}`)
      await this.refresh()
    } catch (e) {
      this.flash(errMsg(e))
      if (btn) { btn.disabled = false; btn.innerHTML = '<span>✓</span> Commit' }
    } finally {
      this.busy = false
    }
  }

  private flash(text: string) {
    const hdr = this.el.querySelector('.changes-header')
    if (!hdr) return
    let note = this.el.querySelector('.changes-note') as HTMLElement | null
    if (!note) {
      note = document.createElement('span')
      note.className = 'changes-note'
      hdr.appendChild(note)
    }
    note.textContent = text
    setTimeout(() => note?.remove(), 3000)
  }
}

function section(title: string, files: GitFileChange[], group: string): string {
  if (files.length === 0) return ''
  return `
    <div class="changes-section-hdr">
      <span>${title}</span>
      <span class="changes-count">${files.length}</span>
    </div>
    ${files.map(f => fileRow(f, group)).join('')}
  `
}

function fileRow(f: GitFileChange, group: string): string {
  const name = f.path.split('/').pop() ?? f.path
  const code = f.untracked ? 'U' : (group === 'staged' ? f.index : f.work).trim() || 'M'
  const stats = f.untracked
    ? `<span class="stat-add">new</span>`
    : `<span class="stat-add">+${f.added}</span><span style="color:var(--text-faint)">, </span><span class="stat-del">-${f.deleted}</span>`
  return `
    <div class="changed-file" data-path="${esc(f.path)}" data-group="${group}" title="${esc(f.path)} — tap to ${group === 'staged' ? 'unstage' : 'stage'}">
      <div class="changed-file-name">
        <span class="git-code git-code-${codeClass(code)}">${esc(code)}</span>
        <span>${esc(name)}</span>
      </div>
      <div class="changed-file-stats">${stats}</div>
    </div>
  `
}

function codeClass(code: string): string {
  switch (code[0]) {
    case 'A': return 'add'
    case 'M': return 'mod'
    case 'D': return 'del'
    case 'R': return 'mod'
    case 'U': return 'new'
    default:  return 'mod'
  }
}

function errMsg(e: unknown): string {
  return e instanceof Error ? e.message : String(e)
}
