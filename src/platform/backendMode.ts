// Backend mode selection + persistence.
//
// Mouse can talk to two kinds of relay host:
//   • 'codespaces' — a relay inside a GitHub Codespace (requires GitHub auth).
//   • 'local'      — a self-hosted relay you run on your own machine/server,
//                    reached directly over ws:// — NO GitHub account needed.
//
// The chosen mode + last local relay URL persist in localStorage so the app
// reopens straight into the working setup.

export type BackendMode = 'codespaces' | 'local'

const MODE_KEY = 'mouse_backend_mode'
const LOCAL_URL_KEY = 'mouse_local_relay_url'

export function getBackendMode(): BackendMode {
  const v = localStorage.getItem(MODE_KEY)
  return v === 'local' ? 'local' : 'codespaces'
}

export function setBackendMode(mode: BackendMode) {
  localStorage.setItem(MODE_KEY, mode)
}

export function getLocalRelayUrl(): string {
  return localStorage.getItem(LOCAL_URL_KEY) ?? ''
}

export function setLocalRelayUrl(url: string) {
  localStorage.setItem(LOCAL_URL_KEY, url.trim())
}

/** Normalize user input into a ws:// or wss:// URL. Accepts host:port, http(s)://, ws(s)://. */
export function normalizeRelayUrl(raw: string): string {
  let s = raw.trim()
  if (!s) return ''
  // Strip a trailing slash for consistency.
  s = s.replace(/\/+$/, '')
  if (/^wss?:\/\//i.test(s)) return s
  if (/^https:\/\//i.test(s)) return 'wss://' + s.slice('https://'.length)
  if (/^http:\/\//i.test(s)) return 'ws://' + s.slice('http://'.length)
  // Bare host[:port] — default to ws:// (loopback/LAN); add :2222 if no port.
  if (!/:\d+/.test(s)) s = s + ':2222'
  return 'ws://' + s
}

/** Convert a ws(s):// relay URL to its http(s):// health-probe URL. */
export function relayHealthUrl(wsUrl: string): string {
  const http = wsUrl.replace(/^ws/i, 'http')
  return http + '/health'
}

/** Demo/local launch flags. */
export function isLocalModeFlag(): boolean {
  if (typeof window === 'undefined') return false
  const q = new URLSearchParams(window.location.search)
  return q.get('local') === '1' || q.has('local')
}
