// Cross-platform GitHub HTTP transport.
//
// GitHub's OAuth/device endpoints (github.com) and REST API (api.github.com)
// do NOT send CORS headers for browser origins. A raw `fetch()` therefore works
// ONLY where something bypasses CORS:
//
//   • iOS / Android (Capacitor) — the CapacitorHttp plugin patches global fetch
//     to use native networking. Pass through untouched.
//   • Electron — there is no CORS in the main process. We bridge to a Node https
//     request via the preload (`window.__electron__.ghFetch`). Works in packaged
//     file:// builds where no dev server exists.
//   • Plain web (vite dev / preview) — route through a same-origin dev proxy
//     (`/__gh`, `/__ghapi`) configured in vite.config.ts, which adds no CORS
//     requirement because the request is same-origin.
//
// A pluggable transport (`setGhTransport`) also lets tests inject canned
// responses (`?mockgh=1`) so the whole auth → picker flow is exercisable with
// no network. This is the path that was previously untested and shipped broken.

export interface GhResponseLike {
  status: number
  statusText: string
  headers: Record<string, string>
  body: string
}

export type GhTransport = (url: string, init: GhRequestInit) => Promise<GhResponseLike>

export interface GhRequestInit {
  method: string
  headers: Record<string, string>
  body?: string
}

let injected: GhTransport | null = null

/** Install a custom transport (used by tests). Pass null to clear. */
export function setGhTransport(t: GhTransport | null) { injected = t }

function isNative(): boolean {
  return !!(globalThis as any).Capacitor?.isNativePlatform?.()
}

function electronBridge(): { ghFetch: (r: GhRequestInit & { url: string }) => Promise<GhResponseLike> } | null {
  const e = (globalThis as any).__electron__
  return e && typeof e.ghFetch === 'function' ? e : null
}

function normalizeHeaders(h: HeadersInit | undefined): Record<string, string> {
  const out: Record<string, string> = {}
  if (!h) return out
  if (h instanceof Headers) { h.forEach((v, k) => { out[k] = v }); return out }
  if (Array.isArray(h)) { for (const [k, v] of h) out[k] = v; return out }
  return { ...(h as Record<string, string>) }
}

function toProxyUrl(url: string): string {
  if (url.startsWith('https://github.com/'))     return '/__gh/'   + url.slice('https://github.com/'.length)
  if (url.startsWith('https://api.github.com/'))  return '/__ghapi/' + url.slice('https://api.github.com/'.length)
  return url
}

/** Detect whether the same-origin GitHub proxy is available (vite dev/preview). */
function hasWebProxy(): boolean {
  // The proxy only exists when served over http(s) by vite. file:// (packaged
  // electron) and capacitor:// have no proxy and must use a bridge / native.
  const proto = (globalThis as any).location?.protocol
  return proto === 'http:' || proto === 'https:'
}

/**
 * GitHub-aware fetch. Same call signature as fetch() for the subset we use
 * (string url + optional method/headers/string body), returning a real Response.
 */
export async function ghFetch(url: string, init: RequestInit = {}): Promise<Response> {
  const method = (init.method || 'GET').toUpperCase()
  const headers = normalizeHeaders(init.headers)
  const body = typeof init.body === 'string' ? init.body : undefined

  // 1) Test/mocked transport wins.
  if (injected) {
    const r = await injected(url, { method, headers, body })
    return new Response(r.body, { status: r.status, statusText: r.statusText, headers: r.headers })
  }

  // 2) Native: CapacitorHttp patched global fetch — no CORS.
  if (isNative()) return fetch(url, init)

  // 3) Electron: route through main process (Node https, no CORS).
  const bridge = electronBridge()
  if (bridge) {
    const r = await bridge.ghFetch({ url, method, headers, body })
    return new Response(r.body, { status: r.status, statusText: r.statusText, headers: r.headers })
  }

  // 4) Plain web served by vite: same-origin proxy.
  if (hasWebProxy()) return fetch(toProxyUrl(url), init)

  // 5) Last resort (e.g. packaged build with no bridge): direct fetch. Will
  //    surface a clear CORS/network error rather than silently hanging.
  return fetch(url, init)
}
