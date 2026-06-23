import type { RepoService, GitCommit } from '../../codespaces/RepoService.ts'

const DOT_PALETTE = ['#f472b6', '#f87171', '#60a5fa', '#a855f7', '#4ade80', '#f59e0b', '#22d3ee']

function esc(s: string): string {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
}

function dotColor(hash: string): string {
  let h = 0
  for (let i = 0; i < hash.length; i++) h = (h * 31 + hash.charCodeAt(i)) >>> 0
  return DOT_PALETTE[h % DOT_PALETTE.length]
}

export class GitGraphView {
  el: HTMLElement
  private repo: RepoService | null = null

  constructor() {
    this.el = document.createElement('div')
    this.el.className = 'view-graph'
    this.el.innerHTML = `<div class="panel-msg">Connect a Codespace to see history.</div>`
  }

  connectRepo(repo: RepoService) {
    this.repo = repo
    this.refresh()
  }

  async refresh() {
    if (!this.repo) return
    try {
      const commits = await this.repo.log(50)
      this.render(commits)
    } catch (e) {
      this.el.innerHTML = `<div class="panel-msg panel-error">${esc(errMsg(e))}</div>`
    }
  }

  private render(commits: GitCommit[]) {
    this.el.innerHTML = `
      <div class="graph-hdr">
        <span class="graph-label">GRAPH</span>
        <div class="graph-tools">
          <span class="graph-tool" id="refresh-btn" title="Refresh">↻</span>
        </div>
      </div>
      <div class="graph-commits" id="graph-commits"></div>
    `
    this.el.querySelector('#refresh-btn')?.addEventListener('click', () => this.refresh())

    const list = this.el.querySelector('#graph-commits')!
    if (commits.length === 0) {
      list.innerHTML = `<div class="panel-msg">No commits yet.</div>`
      return
    }

    for (const c of commits) {
      const color = dotColor(c.hash)
      const tags = c.refs.map(t => {
        const cls = t === 'HEAD' ? 'git-tag-main'
          : t.startsWith('origin/') ? 'git-tag-origin'
          : t.startsWith('tag:') ? 'git-tag-main'
          : 'git-tag-main'
        return `<span class="git-tag ${cls}">${esc(t.replace(/^tag: /, ''))}</span>`
      }).join('')

      const row = document.createElement('div')
      row.className = 'graph-row'
      row.title = `${c.short} ${c.subject}`
      row.innerHTML = `
        <div class="graph-dot" style="background:${color};box-shadow:0 0 6px ${color}44"></div>
        <div class="graph-row-info">
          <div class="graph-row-msg">${esc(c.subject)}</div>
          <div class="graph-row-meta">
            <span class="graph-hash">${esc(c.short)}</span>
            ${tags}
          </div>
        </div>
      `
      list.appendChild(row)
    }
  }
}

function errMsg(e: unknown): string {
  return e instanceof Error ? e.message : String(e)
}
