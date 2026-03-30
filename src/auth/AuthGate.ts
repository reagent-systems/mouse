import { openExternalUrl } from '../platform/openExternalUrl.ts'
import { requestDeviceCode, pollForToken, isGitHubOAuthConfigured } from './GitHubAuth.ts'
import { authLog, getAuthDebugLog } from './authLog.ts'

type DoneCallback = (token: string) => void | Promise<void>

function escapeHtml(s: string): string {
  return s
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
}

export class AuthGate {
  el: HTMLElement
  private onDone: DoneCallback

  constructor(onDone: DoneCallback) {
    this.onDone = onDone
    this.el = document.createElement('div')
    this.el.className = 'auth-gate'
    this.renderLanding()
  }

  private renderLanding() {
    const configured = isGitHubOAuthConfigured()
    const setupBlock = configured
      ? ''
      : `
        <div class="auth-setup-callout">
          <strong>One-time setup</strong>
          <p>Use a <strong>GitHub App</strong> (required for Marketplace) with <strong>Device flow</strong> enabled, or a classic <strong>OAuth App</strong> for local-only experiments.</p>
          <ol class="auth-setup-steps">
            <li>Copy <code>.env.example</code> → <code>.env</code>. Set <code>VITE_GITHUB_CLIENT_ID</code> and <code>VITE_GITHUB_APP_SLUG</code> (from your app URL <code>github.com/apps/your-slug</code>).</li>
            <li>Default <code>VITE_GITHUB_AUTH_KIND=github_app</code> omits OAuth scopes (permissions come from the GitHub App). For legacy OAuth Apps, set <code>VITE_GITHUB_AUTH_KIND=oauth_app</code>.</li>
            <li>Restart <code>npm run dev</code> or rebuild native: <code>npm run build && npm run cap:sync</code>.</li>
          </ol>
          <a class="auth-setup-link" href="https://github.com/settings/apps" target="_blank" rel="noopener">GitHub Apps</a>
          ·
          <a class="auth-setup-link" href="https://github.com/settings/developers" target="_blank" rel="noopener">OAuth Apps</a>
        </div>
      `

    this.el.innerHTML = `
      <div class="auth-card glass">
        <div class="auth-logo">⬡</div>
        <h1 class="auth-title">Mouse</h1>
        <p class="auth-subtitle">Code with AI agents from your phone.<br>Your Codespace. Your code.</p>
        ${setupBlock}
        <button class="auth-btn" id="sign-in-btn" ${configured ? '' : 'disabled'}>
          <svg width="18" height="18" viewBox="0 0 16 16" fill="currentColor">
            <path d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.013 8.013 0 0016 8c0-4.42-3.58-8-8-8z"/>
          </svg>
          ${configured ? 'Sign in with GitHub' : 'Sign in (configure Client ID first)'}
        </button>
        <p class="auth-note">Requires a GitHub account with Codespaces access</p>
      </div>
    `
    const btn = this.el.querySelector('#sign-in-btn') as HTMLButtonElement
    if (configured) {
      btn.addEventListener('click', () => this.startFlow())
    }
  }

  private async startFlow() {
    authLog('info', 'sign_in_clicked', {})
    this.renderLoading('Requesting authorization…')
    try {
      const { device_code, user_code, verification_uri, interval } = await requestDeviceCode()
      this.renderDeviceCode(user_code, verification_uri, device_code, interval)
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : String(err)
      authLog('error', 'sign_in_flow_failed', { message })
      this.renderError(message)
    }
  }

  private renderDeviceCode(code: string, uri: string, deviceCode: string, interval: number) {
    this.el.innerHTML = `
      <div class="auth-card glass">
        <div class="auth-logo">⬡</div>
        <h2 class="auth-step-title">Authorize Mouse</h2>
        <p class="auth-step-hint">Open GitHub in your browser and enter this code:</p>
        <div class="auth-code-display" id="copy-code">${code}</div>
        <p class="auth-copy-hint" id="copy-hint">Tap to copy</p>
        <a class="auth-btn auth-btn-outline" href="${uri}" target="_blank" rel="noopener">
          Open GitHub →
        </a>
        <div class="auth-polling">
          <span class="auth-spinner"></span>
          Waiting for authorization…
        </div>
      </div>
    `
    this.el.querySelector('#copy-code')!.addEventListener('click', () => {
      navigator.clipboard?.writeText(code)
      const hint = this.el.querySelector('#copy-hint') as HTMLElement
      hint.textContent = 'Copied!'
      setTimeout(() => { hint.textContent = 'Tap to copy' }, 2000)
    })

    const link = this.el.querySelector('a')!
    link.addEventListener('click', (e) => {
      if ((window as Window & { __electron__?: unknown }).__electron__) {
        e.preventDefault()
        openExternalUrl(uri)
      }
    })

    pollForToken(deviceCode, interval)
      .then(async (token) => {
        try {
          await Promise.resolve(this.onDone(token))
        } catch (err: unknown) {
          const message = err instanceof Error ? err.message : String(err)
          authLog('error', 'post_sign_in_failed', { message })
          this.renderError(message)
        }
      })
      .catch((err: unknown) => {
        const message = err instanceof Error ? err.message : String(err)
        authLog('error', 'poll_failed', { message })
        this.renderError(message)
      })
  }

  private renderLoading(msg: string) {
    this.el.innerHTML = `
      <div class="auth-card glass">
        <div class="auth-logo">⬡</div>
        <div class="auth-polling">
          <span class="auth-spinner"></span>
          ${msg}
        </div>
      </div>
    `
  }

  private renderError(msg: string) {
    const safe = escapeHtml(msg)
    this.el.innerHTML = `
      <div class="auth-card glass">
        <div class="auth-logo">⬡</div>
        <p class="auth-error">${safe}</p>
        <p class="auth-debug-hint">Open the developer console for lines prefixed with <code>[mouse:auth]</code> (Electron: DevTools may open automatically in dev).</p>
        <div class="auth-error-actions">
          <button class="auth-btn" id="retry-btn">Try Again</button>
          <button class="auth-btn auth-btn-outline" type="button" id="copy-debug-btn">Copy debug log</button>
        </div>
        <p class="auth-copy-hint" id="copy-debug-status" hidden></p>
      </div>
    `
    this.el.querySelector('#retry-btn')!.addEventListener('click', () => this.renderLanding())
    this.el.querySelector('#copy-debug-btn')!.addEventListener('click', async () => {
      const text = getAuthDebugLog() || '(no captured log lines — check the console.)'
      try {
        await navigator.clipboard?.writeText(text)
        const el = this.el.querySelector('#copy-debug-status') as HTMLElement
        el.hidden = false
        el.textContent = 'Debug log copied to clipboard.'
        setTimeout(() => { el.hidden = true }, 3500)
      } catch {
        authLog('error', 'clipboard_failed', {})
      }
    })
  }
}
