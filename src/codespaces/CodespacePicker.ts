import { authKind } from '../auth/GitHubAuth.ts'
import { openExternalUrl } from '../platform/openExternalUrl.ts'
import type { Codespace } from './CodespacesApi.ts'
import {
  listCodespaces,
  waitUntilAvailable,
  isRelayRunning,
  relayWssUrl,
  getRepositoryMetadata,
  createUserCodespace,
} from './CodespacesApi.ts'
import { RELAY_DEVCONTAINER_MERGE_JSON } from './relayAutoStartSnippet.ts'

export interface PickResult {
  codespace: Codespace
  relayUrl: string
  token: string
}

type DoneCallback = (result: PickResult) => void

export class CodespacePicker {
  el: HTMLElement
  private token: string
  private onDone: DoneCallback

  constructor(token: string, onDone: DoneCallback) {
    this.token = token
    this.onDone = onDone
    this.el = document.createElement('div')
    this.el.className = 'picker-screen'
    this.load()
  }

  private async load() {
    this.renderLoading()
    try {
      const list = await listCodespaces(this.token)
      if (list.length === 0) this.renderEmpty()
      else this.renderList(list)
    } catch (err: any) {
      this.renderError(err.message)
    }
  }

  private renderLoading() {
    this.el.innerHTML = `
      <div class="picker-loading picker-loading-full">
        <span class="auth-spinner"></span>
        Loading…
      </div>
    `
  }

  private renderEmpty() {
    const appHint = authKind() === 'github_app'
      ? `<p class="picker-empty-hint">Signed in with a GitHub App? You only see Codespaces for repos that installation can use (needs <strong>Codespaces: Read and write</strong>).</p>`
      : ''
    this.el.innerHTML = `
      <div class="picker-empty">
        <div class="picker-empty-icon">⬡</div>
        <p>No Codespaces yet.</p>
        ${appHint}
        <button type="button" class="auth-btn picker-empty-cta" id="create-btn">
          Create Codespace
        </button>
      </div>
    `
    this.el.querySelector('#create-btn')!.addEventListener('click', () => this.renderCreateForm())
  }

  private renderList(spaces: Codespace[]) {
    this.el.innerHTML = `
      <div class="picker-header picker-header-row">
        <button type="button" class="auth-btn picker-header-btn" id="create-btn">
          Create Codespace
        </button>
      </div>
      <div class="picker-list" id="picker-list"></div>
      <div class="picker-footer">
        <div class="picker-setup-cmd" title="Run inside the Codespace terminal">npx @mouse-app/relay</div>
      </div>
    `
    this.el.querySelector('#create-btn')!.addEventListener('click', () => this.renderCreateForm())
    const list = this.el.querySelector('#picker-list')!
    spaces.forEach(cs => list.appendChild(this.makeCard(cs)))
  }

  private renderCreateForm() {
    this.el.innerHTML = `
      <div class="picker-header">
        <button type="button" class="picker-back" id="back-btn">‹ Back</button>
      </div>
      <div class="picker-create-form">
        <input type="text" class="picker-create-input" id="repo-input"
          placeholder="owner/repo" autocomplete="off" />
        <input type="text" class="picker-create-input" id="branch-input"
          placeholder="branch (optional)" autocomplete="off" />
        <p class="auth-error" id="create-err" hidden></p>
        <button type="button" class="auth-btn" id="submit-create">Create</button>
      </div>
    `
    const errEl = this.el.querySelector('#create-err') as HTMLElement
    const repoInput = this.el.querySelector('#repo-input') as HTMLInputElement
    const branchInput = this.el.querySelector('#branch-input') as HTMLInputElement

    this.el.querySelector('#back-btn')!.addEventListener('click', () => this.load())
    this.el.querySelector('#submit-create')!.addEventListener('click', async () => {
      errEl.hidden = true
      const raw = repoInput.value.trim()
      const parts = raw.split('/').map(s => s.trim()).filter(Boolean)
      if (parts.length !== 2) {
        errEl.textContent = 'Enter repository as owner/repo.'
        errEl.hidden = false
        return
      }
      const [owner, repo] = parts
      const refBranch = branchInput.value.trim()

      const btn = this.el.querySelector('#submit-create') as HTMLButtonElement
      btn.disabled = true
      btn.textContent = 'Creating…'
      try {
        const meta = await getRepositoryMetadata(this.token, owner, repo)
        const ref = refBranch || meta.default_branch
        const cs = await createUserCodespace(this.token, meta.id, ref)
        const live = await waitUntilAvailable(this.token, cs.name, (state) => {
          btn.textContent = state === 'Shutdown' ? 'Starting…' : `${state}…`
        })
        await this.connect(live)
      } catch (e: unknown) {
        const msg = e instanceof Error ? e.message : String(e)
        errEl.textContent = msg
        errEl.hidden = false
        btn.disabled = false
        btn.textContent = 'Create'
      }
    })
  }

  private makeCard(cs: Codespace): HTMLElement {
    const card = document.createElement('div')
    card.className = 'cs-card glass'

    const stateClass = cs.state === 'Available' ? 'state-available'
      : cs.state === 'Shutdown' ? 'state-stopped'
      : 'state-starting'

    const ram = cs.machine
      ? `${Math.round(cs.machine.memory_in_bytes / 1e9)}GB · ${cs.machine.cpus} CPU`
      : ''

    card.innerHTML = `
      <div class="cs-card-top">
        <div class="cs-dot ${stateClass}"></div>
        <div class="cs-info">
          <div class="cs-name">${cs.display_name ?? cs.name}</div>
          <div class="cs-repo">${cs.repository.full_name}</div>
        </div>
        <div class="cs-state-label">${cs.state}</div>
      </div>
      ${ram ? `<div class="cs-meta">${ram}</div>` : ''}
    `
    card.addEventListener('click', () => this.connect(cs))
    return card
  }

  private async connect(cs: Codespace) {
    this.renderConnecting(cs)
    try {
      // 1. Make sure it's running
      const live = await waitUntilAvailable(this.token, cs.name, (state) => {
        const el = this.el.querySelector('.connect-state')
        if (el) el.textContent = state === 'Shutdown' ? 'Starting Codespace…' : state + '…'
      })

      // 2. Check if relay is up
      const statusEl = this.el.querySelector('.connect-state')
      if (statusEl) statusEl.textContent = 'Checking relay…'

      const up = await isRelayRunning(live.name, this.token)
      if (!up) {
        this.renderRelaySetup(live, live)
        return
      }

      // 3. Done — relay is up
      this.onDone({
        codespace: live,
        relayUrl: relayWssUrl(live.name),
        token: this.token,
      })
    } catch (err: any) {
      this.renderError(err.message)
    }
  }

  private renderConnecting(_cs: Codespace) {
    this.el.innerHTML = `
      <div class="picker-header">
        <button class="picker-back" id="back-btn">‹ Back</button>
      </div>
      <div class="picker-loading">
        <span class="auth-spinner"></span>
        <span class="connect-state">Connecting…</span>
      </div>
    `
    this.el.querySelector('#back-btn')!.addEventListener('click', () => this.load())
  }

  private renderRelaySetup(cs: Codespace, live = cs) {
    const web = live.web_url ?? ''
    this.el.innerHTML = `
      <div class="picker-header">
        <button class="picker-back" id="back-btn">‹ Back</button>
        <span class="picker-title">Relay</span>
      </div>
      <div class="relay-setup glass">
        <div class="relay-setup-icon">🔌</div>
        <h3 class="relay-setup-title">Bridge to your Codespace</h3>
        <p class="relay-setup-desc">
          GitHub does not expose a terminal stream to third-party apps. Mouse talks to a small
          <strong>relay</strong> on port ${2222} inside the Codespace. Add the devcontainer snippet
          to your repo so it starts automatically; otherwise run the command once in any terminal.
        </p>
        ${web ? `
        <button type="button" class="auth-btn relay-setup-btn" id="open-web-cs">Open Codespace in browser</button>
        <p class="relay-copy-hint relay-setup-hint">Run the command in the browser&apos;s terminal, then tap Connect here.</p>
        ` : ''}
        <button type="button" class="auth-btn auth-btn-outline relay-setup-btn" id="copy-devcontainer-merge">Copy devcontainer snippet</button>
        <p class="relay-copy-hint" id="copy-merge-hint" hidden></p>
        <p class="relay-copy-hint relay-setup-hint">Merge into <code class="auth-inline-code">.devcontainer/devcontainer.json</code>
        so the relay starts whenever this Codespace resumes.</p>
        <div class="picker-setup-cmd" id="copy-cmd">npx @mouse-app/relay</div>
        <p class="relay-copy-hint" id="copy-hint">Tap to copy command</p>
        <button type="button" class="auth-btn relay-setup-btn" id="connect-btn">
          Connect
        </button>
      </div>
    `
    this.el.querySelector('#back-btn')!.addEventListener('click', () => this.load())
    if (web) {
      this.el.querySelector('#open-web-cs')!.addEventListener('click', () => openExternalUrl(web))
    }
    this.el.querySelector('#copy-devcontainer-merge')!.addEventListener('click', async () => {
      const status = this.el.querySelector('#copy-merge-hint') as HTMLElement
      try {
        await navigator.clipboard?.writeText(RELAY_DEVCONTAINER_MERGE_JSON)
        status.hidden = false
        status.textContent = 'Snippet copied — merge into devcontainer.json and rebuild the Codespace once.'
        setTimeout(() => { status.hidden = true }, 4500)
      } catch { /* ignore */ }
    })
    this.el.querySelector('#copy-cmd')!.addEventListener('click', () => {
      navigator.clipboard?.writeText('npx @mouse-app/relay')
      const hint = this.el.querySelector('#copy-hint') as HTMLElement
      hint.textContent = 'Copied!'
      setTimeout(() => { hint.textContent = 'Tap to copy command' }, 2000)
    })
    this.el.querySelector('#connect-btn')!.addEventListener('click', () => this.connect(live))
  }

  private renderError(msg: string) {
    this.el.innerHTML = `
      <div class="picker-header">
        <button class="picker-back" id="back-btn">‹ Back</button>
      </div>
      <div class="picker-loading">
        <p class="auth-error">${msg}</p>
        <button class="auth-btn" id="back-btn2" style="margin-top:16px">Back</button>
      </div>
    `
    this.el.querySelector('#back-btn')!.addEventListener('click', () => this.load())
    this.el.querySelector('#back-btn2')!.addEventListener('click', () => this.load())
  }
}
