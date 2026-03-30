import { openExternalUrl } from '../platform/openExternalUrl.ts'
import { githubAppInstallPageUrl, publicGithubClientId } from './GitHubAuth.ts'
import { userHasGithubAppInstallation } from './githubAppInstallation.ts'

export class GitHubAppInstallGate {
  el: HTMLElement
  private token: string
  private installUrl: string
  private onReady: () => void

  constructor(token: string, installUrl: string, onReady: () => void) {
    this.token = token
    this.installUrl = installUrl
    this.onReady = onReady
    this.el = document.createElement('div')
    this.el.className = 'auth-gate'
    this.renderMain()
  }

  private renderMain(hint?: string) {
    const hintBlock = hint
      ? `<p class="auth-error auth-install-retry-hint">${hint}</p>`
      : ''
    this.el.innerHTML = `
      <div class="auth-card glass">
        <div class="auth-logo">⬡</div>
        <h2 class="auth-step-title">Install Mouse on GitHub</h2>
        <p class="auth-step-hint auth-install-body">
          Signing in is only the first step. Install this GitHub App on your account (and any orgs) that own your
          repositories, then choose <strong>All repositories</strong> or add each repo. Approve any new permissions GitHub shows.
        </p>
        ${hintBlock}
        <button type="button" class="auth-btn" id="open-install">Open GitHub — Install app</button>
        <button type="button" class="auth-btn auth-btn-outline" id="recheck">I finished on GitHub</button>
      </div>
    `
    this.el.querySelector('#open-install')!.addEventListener('click', () => {
      openExternalUrl(this.installUrl)
    })
    this.el.querySelector('#recheck')!.addEventListener('click', () => this.recheck())
  }

  private renderChecking() {
    this.el.innerHTML = `
      <div class="auth-card glass">
        <div class="auth-logo">⬡</div>
        <div class="auth-polling">
          <span class="auth-spinner"></span>
          Checking installation…
        </div>
      </div>
    `
  }

  private async recheck() {
    this.renderChecking()
    try {
      const ok = await userHasGithubAppInstallation(this.token, publicGithubClientId())
      if (ok) {
        this.onReady()
        return
      }
      this.renderMain(
        'Installation not detected yet. Use the same GitHub App as this build (same Client ID), include every account/org and repo you need, then try again.',
      )
    } catch {
      const fallback = githubAppInstallPageUrl()
      this.el.innerHTML = `
        <div class="auth-card glass">
          <div class="auth-logo">⬡</div>
          <p class="auth-error">Could not reach GitHub to verify. Check your connection, then try again.</p>
          <button type="button" class="auth-btn" id="retry-recheck">Try again</button>
          ${fallback ? `<button type="button" class="auth-btn auth-btn-outline" id="open-install2">Open install page</button>` : ''}
        </div>
      `
      this.el.querySelector('#retry-recheck')!.addEventListener('click', () => this.recheck())
      const o2 = this.el.querySelector('#open-install2')
      if (o2 && fallback) o2.addEventListener('click', () => openExternalUrl(fallback))
    }
  }
}
