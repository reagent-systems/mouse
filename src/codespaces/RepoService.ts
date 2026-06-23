import type { RelaySocket } from '../terminal/RelaySocket.ts'

export interface GitFileChange {
  /** Path relative to the repo root. */
  path: string
  /** Staged (index) status code from `git status --porcelain` (e.g. M, A, D, R, ?). */
  index: string
  /** Worktree status code. */
  work: string
  staged: boolean
  unstaged: boolean
  untracked: boolean
  added: number
  deleted: number
}

export interface GitStatus {
  branch: string
  staged: GitFileChange[]
  unstaged: GitFileChange[]
}

export interface GitCommit {
  hash: string
  short: string
  subject: string
  refs: string[]
}

/** Wrap a path in single quotes for safe use in a shell command. */
function shQuote(p: string): string {
  return `'${p.replace(/'/g, `'\\''`)}'`
}

/**
 * Live view of the connected Codespace's repository, backed by one-shot
 * `exec` calls over the relay (git + standard POSIX tools).
 */
export class RepoService {
  private relay: RelaySocket

  constructor(relay: RelaySocket) {
    this.relay = relay
  }

  private async run(command: string): Promise<string> {
    const { stdout, stderr, code } = await this.relay.exec(command)
    if (code !== 0) {
      const msg = (stderr || stdout || `command failed (exit ${code})`).trim()
      throw new Error(msg)
    }
    return stdout
  }

  /** Tracked + untracked files (respecting .gitignore), as repo-relative paths. */
  async listFiles(): Promise<string[]> {
    const out = await this.run('git ls-files --cached --others --exclude-standard')
    return out
      .split('\n')
      .map(l => l.trim())
      .filter(Boolean)
      .sort((a, b) => a.localeCompare(b))
  }

  /** Raw contents of a repo-relative file. */
  async readFile(path: string): Promise<string> {
    return this.run(`cat -- ${shQuote(path)}`)
  }

  /** Working-tree status grouped into staged vs unstaged/untracked changes. */
  async status(): Promise<GitStatus> {
    const [statusOut, unstagedNum, stagedNum] = await Promise.all([
      this.run('git status --porcelain=v1 --branch'),
      this.run('git diff --numstat').catch(() => ''),
      this.run('git diff --cached --numstat').catch(() => ''),
    ])

    const unstagedCounts = parseNumstat(unstagedNum)
    const stagedCounts = parseNumstat(stagedNum)

    let branch = ''
    const staged: GitFileChange[] = []
    const unstaged: GitFileChange[] = []

    for (const line of statusOut.split('\n')) {
      if (!line) continue
      if (line.startsWith('## ')) {
        branch = parseBranch(line.slice(3))
        continue
      }
      const index = line[0]
      const work = line[1]
      let path = line.slice(3)
      // Renames are reported as "orig -> new"; track the new path.
      const arrow = path.indexOf(' -> ')
      if (arrow !== -1) path = path.slice(arrow + 4)
      path = unquoteGitPath(path)

      const untracked = index === '?' && work === '?'

      if (untracked) {
        unstaged.push(makeChange(path, index, work, { untracked: true }))
        continue
      }
      if (index !== ' ' && index !== '?') {
        const c = stagedCounts.get(path)
        staged.push(makeChange(path, index, work, { staged: true, added: c?.added, deleted: c?.deleted }))
      }
      if (work !== ' ' && work !== '?') {
        const c = unstagedCounts.get(path)
        unstaged.push(makeChange(path, index, work, { unstaged: true, added: c?.added, deleted: c?.deleted }))
      }
    }

    return { branch, staged, unstaged }
  }

  /** Recent commits with their refs/tags. */
  async log(limit = 50): Promise<GitCommit[]> {
    // Field separator \x1f (unit sep), record separator newline.
    const out = await this.run(
      `git log --pretty=format:'%H%x1f%h%x1f%s%x1f%D' --max-count=${limit}`,
    )
    return out
      .split('\n')
      .filter(Boolean)
      .map(line => {
        const [hash = '', short = '', subject = '', refsRaw = ''] = line.split('\x1f')
        const refs = refsRaw
          .split(',')
          .map(r => r.trim().replace(/^HEAD -> /, ''))
          .filter(Boolean)
        return { hash, short, subject, refs }
      })
  }

  async stage(path: string): Promise<void> {
    await this.run(`git add -- ${shQuote(path)}`)
  }

  async unstage(path: string): Promise<void> {
    await this.run(`git reset -q HEAD -- ${shQuote(path)}`)
  }

  /** Commit currently-staged changes. Returns the short hash of the new commit. */
  async commit(message: string): Promise<string> {
    await this.run(`git commit -m ${shQuote(message)}`)
    return (await this.run('git rev-parse --short HEAD')).trim()
  }
}

function makeChange(
  path: string,
  index: string,
  work: string,
  opts: { staged?: boolean; unstaged?: boolean; untracked?: boolean; added?: number; deleted?: number },
): GitFileChange {
  return {
    path,
    index,
    work,
    staged: opts.staged ?? false,
    unstaged: opts.unstaged ?? false,
    untracked: opts.untracked ?? false,
    added: opts.added ?? 0,
    deleted: opts.deleted ?? 0,
  }
}

function parseNumstat(out: string): Map<string, { added: number; deleted: number }> {
  const map = new Map<string, { added: number; deleted: number }>()
  for (const line of out.split('\n')) {
    if (!line.trim()) continue
    const [addStr, delStr, ...rest] = line.split('\t')
    let path = rest.join('\t')
    const arrow = path.indexOf(' => ')
    if (arrow !== -1) path = path.replace(/\{.*? => (.*?)\}/, '$1').replace(/.* => /, '')
    path = unquoteGitPath(path)
    map.set(path, {
      added: addStr === '-' ? 0 : parseInt(addStr, 10) || 0,
      deleted: delStr === '-' ? 0 : parseInt(delStr, 10) || 0,
    })
  }
  return map
}

function parseBranch(raw: string): string {
  // Examples: "main...origin/main [ahead 1]", "No commits yet on main", "HEAD (no branch)"
  const noCommits = raw.match(/^No commits yet on (.+)$/)
  if (noCommits) return noCommits[1].trim()
  const name = raw.split('...')[0].split(' ')[0]
  return name.trim()
}

/** git quotes paths with special characters in double quotes; undo the common cases. */
function unquoteGitPath(p: string): string {
  if (p.startsWith('"') && p.endsWith('"')) {
    try {
      return JSON.parse(p)
    } catch {
      return p.slice(1, -1)
    }
  }
  return p
}
