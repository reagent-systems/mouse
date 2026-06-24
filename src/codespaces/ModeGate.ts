type ChooseCallback = (mode: 'ondevice' | 'codespaces' | 'local') => void

/**
 * First-run mode chooser. On-device is the primary, default path. Local relay
 * and GitHub Codespaces are the remote options. Persisted choice means this is
 * usually skipped on later launches.
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
        <button type="button" class="auth-btn" id="mode-ondevice">On this device</button>
        <button type="button" class="auth-btn auth-btn-outline" id="mode-local">Local relay</button>
        <button type="button" class="auth-btn auth-btn-outline" id="mode-cs">GitHub Codespaces</button>
      </div>
    `
    this.el.querySelector('#mode-ondevice')!.addEventListener('click', () => onChoose('ondevice'))
    this.el.querySelector('#mode-local')!.addEventListener('click', () => onChoose('local'))
    this.el.querySelector('#mode-cs')!.addEventListener('click', () => onChoose('codespaces'))
  }
}
