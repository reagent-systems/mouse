import { normalizeRelayUrl, relayHealthUrl, setLocalRelayUrl, getLocalRelayUrl } from '../platform/backendMode.ts'
import type { PickResult } from '../codespaces/CodespacePicker.ts'
import type { Codespace } from '../codespaces/CodespacesApi.ts'

type DoneCallback = (result: PickResult) => void
type BackCallback = () => void

/**
 * Local relay setup screen. The user points Mouse at a self-hosted relay
 * (their Mac / server / Jetson running `npx @mouse-app/relay --local`). We probe
 * /health to confirm reachability + report the runtime, then hand a PickResult
 * to the app so the module UI connects exactly as it would for a Codespace.
 */
export class LocalGate {
  el: HTMLElement
  private onDone: DoneCallback
  private onBack: BackCallback

  constructor(onDone: DoneCallback, onBack: BackCallback) {
    this.onDone = onDone
    this.onBack = onBack
    this.el = document.createElement('div')
    this.el.className = 'auth-gate'
    this.render()
  }

  private render() {
    const saved = getLocalRelayUrl()
    this.el.innerHTML = `
      <div class="auth-card glass">
        <div class="auth-logo">🖧</div>
        <h2 class="auth-step-title">Local relay</h2>
        <p class="auth-step-hint auth-install-body">
          Run <code class="auth-inline-code">npx @mouse-app/relay --local</code>, then enter its address.
        </p>
        <input type="text" class="picker-create-input" id="relay-url"
          placeholder="192.168.1.50:2222"
          autocomplete="off" autocapitalize="off" spellcheck="false"
          value="${escAttr(saved)}" />
        <p class="auth-error" id="local-err" hidden></p>
        <p class="auth-copy-hint" id="local-status" hidden></p>
        <button type="button" class="auth-btn" id="connect-local">Connect</button>
        <button type="button" class="auth-btn auth-btn-outline" id="local-back">Back</button>
      </div>
    `
    const input = this.el.querySelector('#relay-url') as HTMLInputElement
    const errEl = this.el.querySelector('#local-err') as HTMLElement
    const statusEl = this.el.querySelector('#local-status') as HTMLElement
    const btn = this.el.querySelector('#connect-local') as HTMLButtonElement

    this.el.querySelector('#local-back')!.addEventListener('click', () => this.onBack())
    input.addEventListener('keydown', (e) => { if (e.key === 'Enter') btn.click() })

    btn.addEventListener('click', async () => {
      errEl.hidden = true
      const wsUrl = normalizeRelayUrl(input.value)
      if (!wsUrl) { errEl.textContent = 'Enter the relay address (host:port).'; errEl.hidden = false; return }

      btn.disabled = true
      btn.textContent = 'Connecting…'
      statusEl.hidden = false
      statusEl.textContent = ''

      try {
        const health = await probeHealth(wsUrl)
        setLocalRelayUrl(input.value)
        this.onDone(makeLocalPickResult(wsUrl, health))
      } catch (e) {
        const msg = e instanceof Error ? e.message : String(e)
        errEl.textContent = msg
        errEl.hidden = false
        statusEl.hidden = true
        btn.disabled = false
        btn.textContent = 'Connect'
      }
    })
  }
}

interface RelayHealth { ok: boolean; mode: string; runtime: string; version?: string }

async function probeHealth(wsUrl: string): Promise<RelayHealth> {
  const url = relayHealthUrl(wsUrl)
  const res = await fetch(url, { signal: AbortSignal.timeout(5000) })
  if (!res.ok) throw new Error(`health HTTP ${res.status}`)
  const j = await res.json() as RelayHealth
  if (!j.ok) throw new Error('relay reported not-ok')
  return j
}

/** A synthetic Codespace so the existing app plumbing accepts a local relay. */
function makeLocalPickResult(wsUrl: string, health: RelayHealth): PickResult {
  const codespace: Codespace = {
    name: 'local-relay',
    display_name: `local · ${health.runtime}`,
    state: 'Available',
    repository: { full_name: 'local', html_url: '' },
    machine: null,
    web_url: '',
    created_at: new Date().toISOString(),
    last_used_at: new Date().toISOString(),
  }
  return { codespace, relayUrl: wsUrl, token: 'local' }
}

function escAttr(s: string): string {
  return s.replace(/&/g, '&amp;').replace(/"/g, '&quot;').replace(/</g, '&lt;')
}
