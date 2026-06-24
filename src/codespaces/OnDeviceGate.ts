import { OnDeviceFS } from '../runtime/OnDeviceFS.ts'
import { STARTERS } from '../runtime/starters.ts'
import type { Starter } from '../runtime/starters.ts'

/** Result handed to the app: the opened on-device filesystem to run against. */
export interface OnDeviceResult {
  fs: OnDeviceFS
  workspaceName: string
}

type DoneCallback = (result: OnDeviceResult) => void
type BackCallback = () => void

/**
 * On-device gate. The third — and primary — way to use Mouse: NO host at all.
 * It forks starter files into the device's own filesystem (OPFS) and opens the
 * interface against them. If a workspace already exists, it offers to continue.
 */
export class OnDeviceGate {
  el: HTMLElement
  private onDone: DoneCallback
  private onBack: BackCallback
  private fs: OnDeviceFS | null = null

  constructor(onDone: DoneCallback, onBack: BackCallback) {
    this.onDone = onDone
    this.onBack = onBack
    this.el = document.createElement('div')
    this.el.className = 'auth-gate'
    this.el.innerHTML = `
      <div class="auth-card glass">
        <div class="auth-logo">📱</div>
        <div class="auth-polling"><span class="auth-spinner"></span> Preparing on-device storage…</div>
      </div>
    `
    this.init()
  }

  private async init() {
    this.fs = await OnDeviceFS.open()
    const existing = await this.fs.hasWorkspace()
    this.render(existing)
  }

  private render(hasExisting: boolean) {
    const continueBlock = hasExisting
      ? `<button type="button" class="auth-btn" id="continue-ws">Continue my workspace →</button>
         <p class="auth-copy-hint">Stored on this device (${this.fs?.kind === 'opfs' ? 'persistent' : 'local'}).</p>`
      : ''

    this.el.innerHTML = `
      <div class="auth-card glass">
        <div class="auth-logo">📱</div>
        <h2 class="auth-step-title">Run on this device</h2>
        <p class="auth-step-hint auth-install-body">
          Fork a starter workspace onto your phone and open the interface. No
          GitHub, no relay, no server — files live on-device and persist.
        </p>
        ${continueBlock}
        <div class="starter-list" id="starter-list"></div>
        <button type="button" class="auth-btn auth-btn-outline" id="ondevice-back">‹ Other options</button>
      </div>
    `

    const list = this.el.querySelector('#starter-list') as HTMLElement
    for (const s of STARTERS) list.appendChild(this.makeStarterRow(s))

    this.el.querySelector('#ondevice-back')!.addEventListener('click', () => this.onBack())
    const cont = this.el.querySelector('#continue-ws')
    if (cont) cont.addEventListener('click', () => this.open('my-workspace'))
  }

  private makeStarterRow(s: Starter): HTMLElement {
    const row = document.createElement('button')
    row.className = 'starter-row'
    row.innerHTML = `
      <span class="starter-icon">${s.icon}</span>
      <span class="starter-text">
        <span class="starter-title">${s.title}</span>
        <span class="starter-sub">${s.subtitle}</span>
      </span>
      <span class="starter-go">Fork →</span>
    `
    row.addEventListener('click', async () => {
      row.classList.add('busy')
      const go = row.querySelector('.starter-go') as HTMLElement
      go.textContent = 'Forking…'
      try {
        await this.fs!.forkFiles(s.files, /* overwrite */ false)
        this.open(s.title)
      } catch (e) {
        go.textContent = 'Failed'
        console.error('[mouse] fork failed', e)
      }
    })
    return row
  }

  private open(name: string) {
    if (!this.fs) return
    this.onDone({ fs: this.fs, workspaceName: name })
  }
}
