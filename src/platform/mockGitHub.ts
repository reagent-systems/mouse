// Canned GitHub transport for tests and offline demos. Activated by `?mockgh=1`.
// Drives the entire auth → install-check → codespace-picker flow with no network,
// reproducing real screens (including the "No Codespaces yet" empty state seen on
// the iOS simulator) so the previously-untested auth path is exercisable.
import { setGhTransport } from './githubHttp.ts'
import type { GhResponseLike, GhRequestInit } from './githubHttp.ts'

function json(status: number, obj: unknown): GhResponseLike {
  return {
    status,
    statusText: status === 200 ? 'OK' : 'ERR',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(obj),
  }
}

/** Install the mock transport if `?mockgh=1` (or window.__MOUSE_MOCKGH__). */
export function maybeInstallMockGitHub(): boolean {
  const q = typeof window !== 'undefined' ? new URLSearchParams(window.location.search) : null
  const on = (q && (q.get('mockgh') === '1' || q.has('mockgh'))) || (window as any).__MOUSE_MOCKGH__ === true
  if (!on) return false

  let polls = 0
  setGhTransport(async (url: string, _init: GhRequestInit): Promise<GhResponseLike> => {
    // Device flow: request a user code.
    if (url.includes('/login/device/code')) {
      return json(200, {
        device_code: 'MOCK-DEVICE-CODE',
        user_code: 'WXYZ-1234',
        verification_uri: 'https://github.com/login/device',
        expires_in: 900,
        interval: 0, // poll immediately in tests
      })
    }
    // Device flow: exchange for a token. Pend once, then succeed.
    if (url.includes('/login/oauth/access_token')) {
      polls++
      if (polls < 2) return json(200, { error: 'authorization_pending' })
      return json(200, { access_token: 'MOCK-TOKEN', refresh_token: 'MOCK-REFRESH', token_type: 'bearer' })
    }
    // Authenticated user.
    if (url.endsWith('/user')) {
      return json(200, { login: 'octocat', name: 'Octo Cat', avatar_url: '' })
    }
    // GitHub App installations — report one matching installation so the install
    // gate passes straight through to the picker.
    if (url.includes('/user/installations')) {
      return json(200, { installations: [{ client_id: 'Iv23liFfOa5cNvXvatNB' }] })
    }
    // Codespaces list — empty, to render the "No Codespaces yet" screen.
    if (url.includes('/user/codespaces')) {
      return json(200, { codespaces: [] })
    }
    return json(404, { message: 'mock: unhandled ' + url })
  })
  return true
}
