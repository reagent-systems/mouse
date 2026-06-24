import { ModuleStack } from './modules/ModuleStack.ts'
import { Agent } from './agents/Agent.ts'
import { BottomBar } from './components/BottomBar.ts'
import { AuthGate } from './auth/AuthGate.ts'
import { GitHubAppInstallGate } from './auth/GitHubAppInstallGate.ts'
import { CodespacePicker } from './codespaces/CodespacePicker.ts'
import { RelaySocket } from './terminal/RelaySocket.ts'
import { MockRelay } from './terminal/MockRelay.ts'
import type { RelayLike } from './terminal/MockRelay.ts'
import { isDemoMode, makeDemoPickResult } from './codespaces/demo.ts'
import { ModeGate } from './codespaces/ModeGate.ts'
import { LocalGate } from './codespaces/LocalGate.ts'
import { OnDeviceGate } from './codespaces/OnDeviceGate.ts'
import type { OnDeviceResult } from './codespaces/OnDeviceGate.ts'
import {
  getBackendMode, setBackendMode, isLocalModeFlag, isOnDeviceFlag,
} from './platform/backendMode.ts'
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
  private relay: RelayLike | null = null
  private agentCount = 0

  constructor(container: HTMLElement) {
    this.el = document.createElement('div')
    this.el.className = 'app'
    container.appendChild(this.el)
    this.boot()
  }

  private async boot() {
    // Demo mode (?demo=1): skip auth + live relay, render the full module UI
    // with a scripted MockRelay so every view is visible and verifiable.
    if (isDemoMode()) {
      this.showMain(makeDemoPickResult(), new MockRelay())
      return
    }

    // On-device mode (?ondevice=1 flag): run entirely on this device, no host.
    if (isOnDeviceFlag()) {
      setBackendMode('ondevice')
      this.showOnDeviceGate()
      return
    }

    // Local relay mode (?local=1 flag, or previously chosen): self-hosted relay.
    if (isLocalModeFlag()) {
      setBackendMode('local')
      this.showLocalGate()
      return
    }

    // Mock GitHub (?mockgh=1) implies the Codespaces auth journey for testing —
    // skip the mode chooser and go straight to GitHub sign-in.
    const forceCodespaces = typeof window !== 'undefined'
      && new URLSearchParams(window.location.search).has('mockgh')

    // Returning users keep their chosen backend; first-run sees the chooser.
    const chosen = localStorage.getItem('mouse_backend_mode')
    if (!forceCodespaces && !chosen) {
      this.showModeGate()
      return
    }
    if (!forceCodespaces && getBackendMode() === 'ondevice') {
      this.showOnDeviceGate()
      return
    }
    if (!forceCodespaces && getBackendMode() === 'local') {
      this.showLocalGate()
      return
    }

    // Codespaces path: require GitHub auth.
    const token = await getValidAccessToken()
    if (!token) {
      if (getStoredToken()) clearAuth()
      this.showAuth()
      return
    }
    await this.continueAfterSignIn(token)
  }

  private showModeGate() {
    this.el.innerHTML = ''
    const gate = new ModeGate((mode) => {
      setBackendMode(mode)
      if (mode === 'ondevice') { this.showOnDeviceGate(); return }
      if (mode === 'local') { this.showLocalGate(); return }
      this.boot()
    })
    this.el.appendChild(gate.el)
  }

  private showOnDeviceGate() {
    this.el.innerHTML = ''
    const gate = new OnDeviceGate(
      (result) => { this.el.innerHTML = ''; this.showOnDeviceMain(result) },
      () => { this.showModeGate() },
    )
    this.el.appendChild(gate.el)
  }

  private showLocalGate() {
    this.el.innerHTML = ''
    const gate = new LocalGate(
      (result) => { this.el.innerHTML = ''; this.showMain(result) },
      () => { this.showModeGate() },
    )
    this.el.appendChild(gate.el)
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

  /**
   * On-device interface: the module stack + composer, with NO relay. The
   * composer routes agent tasks to the in-app Python runtime (ScriptTerminal),
   * and views read/write the on-device filesystem. This is the host-free path.
   */
  private showOnDeviceMain(result: OnDeviceResult) {
    const { fs, workspaceName } = result

    const stack     = new ModuleStack()
    const bottomBar = new BottomBar(workspaceName)

    this.el.appendChild(stack.el)
    this.el.appendChild(bottomBar.el)
    ;(window as any).__mouseStack = stack
    ;(window as any).__mouseFS = fs

    // Open onto the script terminal so the user lands directly in a usable,
    // runnable interface — no connection step, no waiting.
    stack.showViewIn('script', 0)
    this.toast(`On-device workspace ready (${fs.kind})`)

    // Composer → run the task on the in-app Python runtime.
    bottomBar.onSubmit(text => {
      stack.runScriptTask(text)
    })

    bottomBar.onSignOut(() => {
      this.el.innerHTML = ''
      this.boot()
    })
  }

  private showMain(result: PickResult, relayOverride?: RelayLike) {
    const { token, relayUrl, codespace } = result
    const codespaceName = codespace.display_name ?? codespace.name

    const stack     = new ModuleStack()
    const bottomBar = new BottomBar(codespaceName)

    this.el.appendChild(stack.el)
    this.el.appendChild(bottomBar.el)

    // Demo hook: expose the stack so the verification harness (and manual
    // testing) can navigate views without simulating touch gestures.
    if (isDemoMode()) (window as any).__mouseStack = stack

    // ── Connect relay ──────────────────────────────────
    this.relay = relayOverride ?? new RelaySocket(relayUrl, token)

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
