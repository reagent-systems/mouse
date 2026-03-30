import { authLog } from './authLog.ts'

const BASE = 'https://api.github.com'

function apiHeaders(token: string) {
  return {
    'Authorization': `Bearer ${token}`,
    'Accept': 'application/vnd.github+json',
    'X-GitHub-Api-Version': '2022-11-28',
  }
}

/** True if an installation of the GitHub App (matching OAuth `client_id`) exists for this user. */
export async function userHasGithubAppInstallation(token: string, clientId: string): Promise<boolean> {
  const target = clientId.trim().toLowerCase()
  if (!target) return false

  let page = 1
  const perPage = 100
  for (;;) {
    const res = await fetch(
      `${BASE}/user/installations?per_page=${perPage}&page=${page}`,
      { headers: apiHeaders(token) },
    )
    if (!res.ok) {
      const snippet = await res.text().then(t => t.slice(0, 240)).catch(() => '')
      authLog('error', 'list_user_installations_failed', { status: res.status, snippet })
      throw new Error(`GitHub installations: HTTP ${res.status}`)
    }
    const data = await res.json() as { installations?: Array<{ client_id?: string }> }
    const list = data.installations ?? []
    for (const inst of list) {
      const cid = typeof inst.client_id === 'string' ? inst.client_id.trim().toLowerCase() : ''
      if (cid && cid === target) return true
    }
    if (list.length < perPage) break
    page++
    if (page > 25) break // safety
  }
  return false
}
