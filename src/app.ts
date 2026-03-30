import { ModuleStack } from './modules/ModuleStack.ts'
import { Agent } from './agents/Agent.ts'
import { BottomBar } from './components/BottomBar.ts'
import { AuthGate } from './auth/AuthGate.ts'
import { GitHubAppInstallGate } from './auth/GitHubAppInstallGate.ts'
import { CodespacePicker } from './codespaces/CodespacePicker.ts'
import { RelaySocket } from './terminal/RelaySocket.ts'
import {
  authKind,
  clearAuth,
  getStoredToken,
  getValidAccessToken,
  githubAppInstallPageUrl,
  publicGithubClientId,
} from './auth/GitHubAuth.ts'
import { userHasGithubAppInstallation } from './auth/githubAppInstallation.ts'
import { authLog } from './auth/authLog.ts'
import { openExternalUrl } from './platform/openExternalUrl.ts'
import type { PickResult } from './codespaces/CodespacePicker.ts'

export class App {
  el: HTMLElement
  private relay: RelaySocket | null = null
  private agentCount = 0

  constructor(container: HTMLElement) {
    this.el = document.createElement('div')
    this.el.className = 'app'
    container.appendChild(this.el)
    this.boot()
  }

  private async boot() {
    const token = await getValidAccessToken()
    if (!token) {
      if (getStoredToken()) clearAuth()
      this.showAuth()
      return
    }
    await this.continueAfterSignIn(token)
  }

  private showAuth() {
    this.el.innerHTML = ''
    const gate = new AuthGate(async (token) => {
      this.el.innerHTML = ''
      await this.continueAfterSignIn(token)
    })
    this.el.appendChild(gate.el)
  }

  /** GitHub App: ensure the app is installed (user-to-server tokens are scoped to installations). */
  private async continueAfterSignIn(token: string) {
    if (authKind() !== 'github_app') {
      this.showCodespacePicker(token)
      return
    }

    this.showInstallCheckLoading()
    let installed = false
    try {
      installed = await userHasGithubAppInstallation(token, publicGithubClientId())
    } catch (e) {
      authLog('warn', 'github_app_install_check_failed', {
        message: e instanceof Error ? e.message : String(e),
      })
    }

    if (installed) {
      this.showCodespacePicker(token)
      return
    }

    const url = githubAppInstallPageUrl()
    if (!url) {
      this.showGitHubAppSlugMissing()
      return
    }

    this.showGitHubAppInstallGate(token, url)
  }

  private showInstallCheckLoading() {
    this.el.innerHTML = ''
    const wrap = document.createElement('div')
    wrap.className = 'auth-gate'
    wrap.innerHTML = `
      <div class="auth-card glass">
        <div class="auth-logo">⬡</div>
        <div class="auth-polling">
          <span class="auth-spinner"></span>
          Checking GitHub App installation…
        </div>
      </div>
    `
    this.el.appendChild(wrap)
  }

  private showGitHubAppSlugMissing() {
    this.el.innerHTML = ''
    const wrap = document.createElement('div')
    wrap.className = 'auth-gate'
    wrap.innerHTML = `
      <div class="auth-card glass">
        <div class="auth-logo">⬡</div>
        <h2 class="auth-step-title">Add your app slug</h2>
        <p class="auth-step-hint auth-install-body">
          Add <code class="auth-inline-code">VITE_GITHUB_APP_SLUG</code> to <code class="auth-inline-code">.env</code>
          (the segment from your app’s public URL:
          <code class="auth-inline-code">github.com/apps/<em>slug-here</em></code>), then rebuild
          (<code class="auth-inline-code">npm run build && npx cap sync</code>) and sign in again.
        </p>
        <button type="button" class="auth-btn" id="open-apps">GitHub — Your GitHub Apps</button>
        <button type="button" class="auth-btn auth-btn-outline" id="slug-signout">Sign out</button>
      </div>
    `
    wrap.querySelector('#open-apps')!.addEventListener('click', () => {
      openExternalUrl('https://github.com/settings/apps')
    })
    wrap.querySelector('#slug-signout')!.addEventListener('click', () => {
      clearAuth()
      this.showAuth()
    })
    this.el.appendChild(wrap)
  }

  private showGitHubAppInstallGate(token: string, installUrl: string) {
    this.el.innerHTML = ''
    const gate = new GitHubAppInstallGate(token, installUrl, () => {
      this.showCodespacePicker(token)
    })
    this.el.appendChild(gate.el)
  }

  private showCodespacePicker(token: string) {
    this.el.innerHTML = ''
    const picker = new CodespacePicker(token, (result) => {
      this.el.innerHTML = ''
      this.showMain(result)
    })
    this.el.appendChild(picker.el)
  }

  private showMain(result: PickResult) {
    const { token, relayUrl, codespace } = result
    const codespaceName = codespace.display_name ?? codespace.name

    const stack     = new ModuleStack()
    const bottomBar = new BottomBar(codespaceName)

    this.el.appendChild(stack.el)
    this.el.appendChild(bottomBar.el)

    // ── Connect relay ──────────────────────────────────
    this.relay = new RelaySocket(relayUrl, token)

    this.relay.onStatus(status => {
      if (status === 'connected') {
        this.relay!.startSession('terminal', 'bash')
        this.relay!.onSessionStarted('terminal', () => {
          stack.connectTerminal(this.relay!, 'terminal', 'Terminal')
        })
        this.toast(`Connected to ${codespaceName}`)
      }
      if (status === 'disconnected') this.toast('Terminal disconnected')
      if (status === 'error')        this.toast('Connection error — is the relay running?')
    })

    this.relay.connect()

    // ── Composer → new agent module in the stack ──────
    bottomBar.onSubmit(text => {
      if (!this.relay || this.relay.status !== 'connected') {
        this.toast('Not connected to a Codespace')
        return
      }
      this.agentCount++
      const agentId   = `agent-${this.agentCount}`
      const agentName = `Agent ${this.agentCount}`
      const agent     = new Agent(agentId, agentName, this.relay)

      stack.addAgent(agent, this.relay)
      agent.start(text)
    })

    bottomBar.onSignOut(() => {
      this.relay?.disconnect()
      clearAuth()
      this.el.innerHTML = ''
      this.boot()
    })
  }

  private toast(msg: string) {
    const t = document.createElement('div')
    t.className = 'toast'
    t.textContent = msg
    this.el.appendChild(t)
    setTimeout(() => t.classList.add('toast-show'), 10)
    setTimeout(() => {
      t.classList.remove('toast-show')
      setTimeout(() => t.remove(), 300)
    }, 2500)
  }
}
