type ChooseCallback = (mode: 'ondevice' | 'codespaces' | 'local') => void

/**
 * First-run mode chooser. On-device is the primary, default path: run agents
 * entirely on THIS device, no host or account. Local relay and GitHub Codespaces
 * are the remote options. Persisted choice means this is usually skipped later.
 */
export class ModeGate {
  el: HTMLElement

  constructor(onChoose: ChooseCallback) {
    this.el = document.createElement('div')
    this.el.className = 'auth-gate'
    this.el.innerHTML = `
      <div class="auth-card glass">
        <div class="auth-logo">⬡</div>
        <h1 class="auth-title">Mouse</h1>
        <p class="auth-subtitle">Where should your agents run?</p>
        <button type="button" class="auth-btn" id="mode-ondevice">
          📱 On this device <span style="opacity:.7;font-weight:400">— no host needed</span>
        </button>
        <button type="button" class="auth-btn auth-btn-outline" id="mode-local">
          🖧 Local relay <span style="opacity:.7;font-weight:400">— another machine</span>
        </button>
        <button type="button" class="auth-btn auth-btn-outline" id="mode-cs">
           GitHub Codespaces
        </button>
        <p class="auth-note">On-device forks files locally and runs in-app — no account, no network.</p>
      </div>
    `
    this.el.querySelector('#mode-ondevice')!.addEventListener('click', () => onChoose('ondevice'))
    this.el.querySelector('#mode-local')!.addEventListener('click', () => onChoose('local'))
    this.el.querySelector('#mode-cs')!.addEventListener('click', () => onChoose('codespaces'))
  }
}
