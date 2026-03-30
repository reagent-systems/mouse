import { authLog } from './authLog.ts'

/** Marketplace listings require a GitHub App. OAuth App is for legacy / quick dev only. */
export type GitHubAuthKind = 'github_app' | 'oauth_app'

const TOKEN_KEY = 'mouse_gh_token'
const REFRESH_KEY = 'mouse_gh_refresh'
const USER_KEY = 'mouse_gh_user'

/** Shipped default; public, not secret. Override with `VITE_GITHUB_CLIENT_ID` in `.env` when needed. */
const EMBEDDED_GITHUB_CLIENT_ID = 'Iv23liFfOa5cNvXvatNB'

/** Optional; used for https://github.com/apps/&lt;slug&gt;/installations/new when not in .env */
const EMBEDDED_GITHUB_APP_SLUG = ''

const CLIENT_PLACEHOLDERS = new Set([
  'your_github_oauth_app_client_id',
  'your_github_app_client_id',
])

const SLUG_PLACEHOLDERS = new Set(['', 'your_github_app_slug'])

export interface DeviceCodeResponse {
  device_code: string
  user_code: string
  verification_uri: string
  expires_in: number
  interval: number
}

export interface GitHubUser {
  login: string
  name: string
  avatar_url: string
}

export function authKind(): GitHubAuthKind {
  const v = (import.meta.env.VITE_GITHUB_AUTH_KIND as string | undefined)?.trim().toLowerCase()
  if (v === 'oauth' || v === 'oauth_app') return 'oauth_app'
  return 'github_app'
}

function oauthDeviceScopes(): string {
  const custom = import.meta.env.VITE_GITHUB_DEVICE_SCOPES
  if (typeof custom === 'string' && custom.trim()) return custom.trim()
  return 'codespace user:email'
}

function isPlaceholderClientId(id: string): boolean {
  return !id || CLIENT_PLACEHOLDERS.has(id)
}

function effectiveClientId(): string {
  const raw = typeof import.meta.env.VITE_GITHUB_CLIENT_ID === 'string'
    ? import.meta.env.VITE_GITHUB_CLIENT_ID.trim()
    : ''
  if (raw && !isPlaceholderClientId(raw)) return raw
  return EMBEDDED_GITHUB_CLIENT_ID.trim()
}

function effectiveAppSlug(): string {
  const raw = typeof import.meta.env.VITE_GITHUB_APP_SLUG === 'string'
    ? import.meta.env.VITE_GITHUB_APP_SLUG.trim()
    : ''
  if (raw && !SLUG_PLACEHOLDERS.has(raw)) return raw
  return EMBEDDED_GITHUB_APP_SLUG.trim()
}

/** OAuth App / GitHub App Client ID used in API responses (e.g. matching `/user/installations`). */
export function publicGithubClientId(): string {
  return effectiveClientId()
}

/**
 * Public install URL for this GitHub App. Requires `VITE_GITHUB_APP_SLUG` (or embedded slug) so we can
 * link to `https://github.com/apps/&lt;slug&gt;/installations/new` before any installation exists.
 */
export function githubAppInstallPageUrl(): string | null {
  const slug = effectiveAppSlug()
  if (!slug) return null
  return `https://github.com/apps/${encodeURIComponent(slug)}/installations/new`
}

/** True when a Client ID is available (embedded default or non-placeholder `VITE_GITHUB_CLIENT_ID`). */
export function isGitHubOAuthConfigured(): boolean {
  return Boolean(effectiveClientId())
}

function requireClientId(): string {
  const id = effectiveClientId()
  if (!id) {
    authLog('error', 'missing_client_id', { hint: 'set VITE_GITHUB_CLIENT_ID or EMBEDDED_GITHUB_CLIENT_ID in GitHubAuth.ts' })
    throw new Error(
      'GitHub is not configured. Set VITE_GITHUB_CLIENT_ID in .env or EMBEDDED_GITHUB_CLIENT_ID in GitHubAuth.ts.',
    )
  }
  return id
}

/**
 * GitHub OAuth/device endpoints return JSON when Accept: application/json is sent;
 * otherwise the body is application/x-www-form-urlencoded. Capacitor's native
 * Http stack often gets the form encoding even on 200 — parse both.
 */
function parseGithubOAuthBody(text: string): Record<string, unknown> {
  const t = text.trim()
  if (!t) return {}
  if (t.startsWith('{') && t.endsWith('}')) {
    try {
      return JSON.parse(t) as Record<string, unknown>
    } catch {
      /* fall through to form */
    }
  }
  const out: Record<string, unknown> = {}
  for (const [k, v] of new URLSearchParams(t).entries()) {
    out[k] = v
  }
  return out
}

async function readGithubJson(res: Response, context: string): Promise<Record<string, unknown>> {
  const text = await res.text()
  const data = parseGithubOAuthBody(text)
  const looksEmpty = Object.keys(data).length === 0 && text.trim() !== ''
  if (looksEmpty) {
    const snippet = text.slice(0, 400)
    authLog('error', 'oauth_body_parse_failed', { context, status: res.status, snippet })
    throw new Error(`${context}: unrecognized response body (HTTP ${res.status}): ${snippet || '(empty)'}`)
  }

  if (!res.ok) {
    const msg = [data.error, data.error_description].filter(Boolean).join(' — ') || `HTTP ${res.status}`
    authLog('error', 'http_error', { context, status: res.status, ...data })
    throw new Error(`${context}: ${msg}`)
  }
  return data
}

function persistSession(accessToken: string, refreshToken: string | undefined) {
  localStorage.setItem(TOKEN_KEY, accessToken)
  if (refreshToken) localStorage.setItem(REFRESH_KEY, refreshToken)
  else localStorage.removeItem(REFRESH_KEY)
}

export function getStoredToken(): string | null {
  return localStorage.getItem(TOKEN_KEY)
}

export function getStoredUser(): GitHubUser | null {
  const raw = localStorage.getItem(USER_KEY)
  return raw ? JSON.parse(raw) : null
}

export function clearAuth() {
  localStorage.removeItem(TOKEN_KEY)
  localStorage.removeItem(REFRESH_KEY)
  localStorage.removeItem(USER_KEY)
}

/**
 * Refresh a GitHub App user-to-server token (device flow does not require client_secret).
 * No-op if there is no refresh token (e.g. classic OAuth App device flow).
 */
export async function refreshAccessToken(): Promise<string | null> {
  const refresh = localStorage.getItem(REFRESH_KEY)
  const client_id = (() => {
    try {
      return requireClientId()
    } catch {
      return null
    }
  })()
  if (!refresh || !client_id) return null

  const body = new URLSearchParams({
    client_id,
    grant_type: 'refresh_token',
    refresh_token: refresh,
  }).toString()

  let res: Response
  try {
    res = await fetch('https://github.com/login/oauth/access_token', {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body,
    })
  } catch (e) {
    authLog('error', 'refresh_fetch_failed', { error: e instanceof Error ? e.message : String(e) })
    return null
  }

  const text = await res.text()
  const data = parseGithubOAuthBody(text)

  if (!res.ok || !data.access_token) {
    authLog('error', 'refresh_failed', { status: res.status, ...data })
    return null
  }

  const access = data.access_token as string
  const nextRefresh = typeof data.refresh_token === 'string' ? data.refresh_token : refresh
  persistSession(access, nextRefresh)
  authLog('info', 'token_refreshed', {})
  return access
}

export async function requestDeviceCode(): Promise<DeviceCodeResponse> {
  const client_id = requireClientId()
  authLog('info', 'device_code_request_start', { kind: authKind() })
  const params: Record<string, string> = { client_id }
  // GitHub App user tokens use app permissions — omit scope on /login/device/code (see GitHub docs).
  if (authKind() === 'oauth_app') params.scope = oauthDeviceScopes()

  let res: Response
  try {
    const body = new URLSearchParams(params).toString()
    res = await fetch('https://github.com/login/device/code', {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body,
    })
  } catch (e) {
    const err = e instanceof Error ? e.message : String(e)
    authLog('error', 'device_code_fetch_failed', { error: err })
    throw new Error(`Could not reach GitHub (network / DNS / firewall). ${err}`)
  }

  const data = await readGithubJson(res, 'Device code request')
  authLog('info', 'device_code_ok', { expires_in: data.expires_in })
  return {
    device_code: String(data.device_code ?? ''),
    user_code: String(data.user_code ?? ''),
    verification_uri: String(data.verification_uri ?? ''),
    expires_in: Number(data.expires_in),
    interval: Number(data.interval ?? 5),
  }
}

export async function pollForToken(deviceCode: string, intervalSecs: number): Promise<string> {
  const client_id = requireClientId()
  const delay = (ms: number) => new Promise(r => setTimeout(r, ms))
  const ms = Math.max(intervalSecs, 5) * 1000

  for (let attempt = 0; attempt < 60; attempt++) {
    await delay(ms)
    let res: Response
    try {
      const body = new URLSearchParams({
        client_id,
        device_code: deviceCode,
        grant_type: 'urn:ietf:params:oauth:grant-type:device_code',
      }).toString()
      res = await fetch('https://github.com/login/oauth/access_token', {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        body,
      })
    } catch (e) {
      const err = e instanceof Error ? e.message : String(e)
      authLog('error', 'token_poll_fetch_failed', { attempt, error: err })
      throw new Error(`Token poll: could not reach GitHub. ${err}`)
    }

    const text = await res.text()
    const data = parseGithubOAuthBody(text)

    if (!res.ok) {
      const msg = [data.error, data.error_description].filter(Boolean).join(' — ') || `HTTP ${res.status}`
      authLog('error', 'token_poll_http_error', { attempt, status: res.status, ...data })
      throw new Error(msg)
    }

    if (data.access_token) {
      const token = data.access_token as string
      const refresh = typeof data.refresh_token === 'string' ? data.refresh_token : undefined
      persistSession(token, refresh)
      let user: GitHubUser
      try {
        user = await fetchUser(token)
        localStorage.setItem(USER_KEY, JSON.stringify(user))
      } catch (e) {
        const err = e instanceof Error ? e.message : String(e)
        authLog('error', 'fetch_user_after_token_failed', { error: err })
        throw e
      }
      authLog('info', 'token_received_ok', { login: user.login, has_refresh: Boolean(refresh) })
      return token
    }

    const oauthErr = data.error as string | undefined
    if (oauthErr === 'authorization_pending') continue
    if (oauthErr === 'slow_down') {
      authLog('warn', 'token_poll_slow_down', { attempt })
      await delay(5000)
      continue
    }
    if (oauthErr === 'expired_token') {
      authLog('error', 'expired_token', {})
      throw new Error('Device code expired. Please try again.')
    }
    if (oauthErr === 'access_denied') {
      authLog('error', 'access_denied', {})
      throw new Error('Authorization was denied.')
    }
    if (oauthErr) {
      const msg = [oauthErr, data.error_description].filter(Boolean).join(' — ')
      authLog('error', 'token_poll_unknown_oauth_error', { attempt, ...data })
      throw new Error(msg)
    }

    authLog('warn', 'token_poll_empty_response', { attempt, keys: Object.keys(data) })
  }
  authLog('error', 'token_poll_timeout', {})
  throw new Error('Timed out waiting for authorization.')
}

export async function fetchUser(token: string): Promise<GitHubUser> {
  const res = await fetch('https://api.github.com/user', {
    headers: { 'Authorization': `Bearer ${token}`, 'Accept': 'application/vnd.github+json' },
  })
  if (!res.ok) {
    const text = await res.text()
    let detail = `HTTP ${res.status}`
    try {
      const j = JSON.parse(text) as Record<string, unknown>
      detail = [j.message, j.documentation].filter(Boolean).join(' — ') || detail
    } catch {
      detail = text.slice(0, 200) || detail
    }
    authLog('error', 'fetch_user_failed', { status: res.status, detail })
    throw new Error(`Failed to fetch GitHub profile: ${detail}`)
  }
  return res.json()
}

export async function validateToken(token: string): Promise<boolean> {
  try {
    const res = await fetch('https://api.github.com/user', {
      headers: { 'Authorization': `Bearer ${token}` },
    })
    return res.ok
  } catch {
    return false
  }
}

/** If the access token is invalid, try GitHub App refresh (no secret required for device-flow tokens). */
export async function getValidAccessToken(): Promise<string | null> {
  const stored = getStoredToken()
  if (!stored) return null
  if (await validateToken(stored)) return stored
  authLog('info', 'access_token_stale_try_refresh', {})
  const refreshed = await refreshAccessToken()
  if (refreshed && await validateToken(refreshed)) return refreshed
  return null
}
