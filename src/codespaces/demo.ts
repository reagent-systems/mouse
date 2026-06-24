import type { Codespace } from './CodespacesApi.ts'
import type { PickResult } from './CodespacePicker.ts'

/** True when the app should run without live GitHub auth + relay (`?demo=1`). */
export function isDemoMode(): boolean {
  if (typeof window === 'undefined') return false
  const q = new URLSearchParams(window.location.search)
  if (q.get('demo') === '1' || q.has('demo')) return true
  return (window as any).__MOUSE_DEMO__ === true
}

/** A believable Codespace + relay target for demo rendering. */
export function makeDemoPickResult(): PickResult {
  const codespace: Codespace = {
    name: 'mouse-demo-codespace',
    display_name: 'mouse · demo',
    state: 'Available',
    repository: {
      full_name: 'reagent-systems/mouse',
      html_url: 'https://github.com/reagent-systems/mouse',
    },
    machine: {
      name: 'basicLinux32gb',
      display_name: '2-core · 8 GB RAM',
      cpus: 2,
      memory_in_bytes: 8 * 1024 * 1024 * 1024,
    },
    web_url: 'https://example.app.github.dev',
    created_at: new Date(Date.now() - 86_400_000).toISOString(),
    last_used_at: new Date().toISOString(),
  }
  return { codespace, relayUrl: 'wss://demo.invalid/relay', token: 'demo-token' }
}
