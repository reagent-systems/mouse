import { authKind } from '../auth/GitHubAuth.ts'

const BASE = 'https://api.github.com'
const RELAY_PORT = 2222

function headers(token: string) {
  return {
    'Authorization': `Bearer ${token}`,
    'Accept': 'application/vnd.github+json',
    'X-GitHub-Api-Version': '2022-11-28',
  }
}

export interface Codespace {
  name: string
  display_name: string | null
  state: 'Available' | 'Shutdown' | 'Starting' | 'Stopping' | 'Rebuilding' | string
  repository: { full_name: string; html_url: string }
  machine: { name: string; display_name: string; cpus: number; memory_in_bytes: number } | null
  web_url: string
  created_at: string
  last_used_at: string | null
}

/** Explains GitHub’s integration / permission errors for Codespaces (GitHub App vs OAuth). */
export function codespacesAccessHint(apiMessage: string): string {
  const lower = apiMessage.toLowerCase()
  const integrationBlocked =
    lower.includes('not accessible by integration')
    || lower.includes('not accessibly by integration')

  if (!integrationBlocked) return apiMessage

  if (authKind() === 'github_app') {
    return `${apiMessage}

GitHub App sign-in only lists and creates Codespaces for repositories your app installation can access, and only if the app has Repository → Codespaces set to Read and write. Open GitHub → Settings → Developer settings → GitHub Apps → your app, update that permission, then open Install App and ensure the installation includes every user/org and repo you use (accept any new permission prompts).

If you are testing for yourself only, you can switch to a classic OAuth App: set VITE_GITHUB_AUTH_KIND=oauth_app and the codespace scope (see .env.example).`
  }

  return `${apiMessage}

Use an OAuth App that requests the codespace scope, then sign out in Mouse and authorize again so the token includes it.`
}

async function readApiErrorMessage(res: Response, fallback: string): Promise<string> {
  try {
    const j = await res.json() as { message?: string }
    if (typeof j.message === 'string' && j.message.trim()) return j.message.trim()
  } catch { /* ignore */ }
  return fallback
}

export async function listCodespaces(token: string): Promise<Codespace[]> {
  const res = await fetch(`${BASE}/user/codespaces`, { headers: headers(token) })
  if (!res.ok) {
    const msg = await readApiErrorMessage(res, `Failed to list Codespaces (HTTP ${res.status})`)
    throw new Error(codespacesAccessHint(msg))
  }
  const data = await res.json()
  return data.codespaces ?? []
}

export interface RepoMetadata {
  id: number
  full_name: string
  default_branch: string
}

/** Resolve `owner/name` to numeric repo id for Codespace create API. */
export async function getRepositoryMetadata(
  token: string,
  owner: string,
  repo: string,
): Promise<RepoMetadata> {
  const res = await fetch(
    `${BASE}/repos/${encodeURIComponent(owner)}/${encodeURIComponent(repo)}`,
    { headers: headers(token) },
  )
  if (!res.ok) {
    const detail = await readApiErrorMessage(res, `HTTP ${res.status}`)
    throw new Error(codespacesAccessHint(`Repository unavailable: ${detail}`))
  }
  const data = await res.json() as {
    id: number
    full_name: string
    default_branch?: string
  }
  return {
    id: data.id,
    full_name: data.full_name,
    default_branch: data.default_branch ?? 'main',
  }
}

/** Create a new Codespace for the authenticated user (POST /user/codespaces). */
export async function createUserCodespace(
  token: string,
  repositoryId: number,
  ref: string,
): Promise<Codespace> {
  const res = await fetch(`${BASE}/user/codespaces`, {
    method: 'POST',
    headers: {
      ...headers(token),
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({ repository_id: repositoryId, ref }),
  })
  if (res.status !== 201 && res.status !== 202) {
    const msg = await readApiErrorMessage(res, `Could not create Codespace (HTTP ${res.status})`)
    throw new Error(codespacesAccessHint(msg))
  }
  return res.json() as Promise<Codespace>
}

export async function getCodespace(token: string, name: string): Promise<Codespace> {
  const res = await fetch(`${BASE}/user/codespaces/${name}`, { headers: headers(token) })
  if (!res.ok) throw new Error(`Failed to get Codespace: ${res.status}`)
  return res.json()
}

export async function startCodespace(token: string, name: string): Promise<void> {
  const res = await fetch(`${BASE}/user/codespaces/${name}/start`, {
    method: 'POST',
    headers: headers(token),
  })
  if (!res.ok) throw new Error(`Failed to start Codespace: ${res.status}`)
}

export async function waitUntilAvailable(
  token: string,
  name: string,
  onStatus?: (state: string) => void,
): Promise<Codespace> {
  for (let i = 0; i < 60; i++) {
    const cs = await getCodespace(token, name)
    onStatus?.(cs.state)
    if (cs.state === 'Available') return cs
    if (cs.state === 'Shutdown') await startCodespace(token, name)
    await new Promise(r => setTimeout(r, 2000))
  }
  throw new Error('Codespace did not become available in time.')
}

export interface ForwardedPort {
  port: number
  visibility: 'private' | 'public' | 'org'
  label: string
}

export async function listPorts(token: string, name: string): Promise<ForwardedPort[]> {
  const res = await fetch(`${BASE}/user/codespaces/${name}/ports`, { headers: headers(token) })
  if (!res.ok) return []
  const data = await res.json()
  return data.ports ?? []
}

/** Returns the WSS URL for the mouse relay running in this Codespace. */
export function relayWssUrl(codespaceName: string): string {
  return `wss://${codespaceName}-${RELAY_PORT}.app.github.dev`
}

/** Returns the HTTPS URL for the mouse relay (used to check if it's up). */
export function relayHttpUrl(codespaceName: string): string {
  return `https://${codespaceName}-${RELAY_PORT}.app.github.dev/health`
}

/** Check whether the relay is reachable (relay serves GET /health). */
export async function isRelayRunning(codespaceName: string, token: string): Promise<boolean> {
  try {
    const res = await fetch(relayHttpUrl(codespaceName), {
      headers: { 'X-Github-Token': token },
      signal: AbortSignal.timeout(4000),
    })
    return res.ok
  } catch {
    return false
  }
}
