import { describe, it, expect } from 'vitest'
import { RepoService } from './RepoService.ts'
import type { ExecResult, RelaySocket } from '../terminal/RelaySocket.ts'

/** Build a RepoService backed by a stubbed relay whose exec output is decided by `route`. */
function makeRepo(route: (cmd: string) => Partial<ExecResult>) {
  const calls: string[] = []
  const relay = {
    exec: async (command: string): Promise<ExecResult> => {
      calls.push(command)
      const r = route(command)
      return { stdout: r.stdout ?? '', stderr: r.stderr ?? '', code: r.code ?? 0 }
    },
  } as unknown as RelaySocket
  return { repo: new RepoService(relay), calls }
}

describe('RepoService.listFiles', () => {
  it('splits, trims, de-blanks and sorts the file list', async () => {
    const { repo, calls } = makeRepo(() => ({ stdout: 'src/b.ts\na.ts\n\n  README.md  \n' }))
    const files = await repo.listFiles()
    // Sorted with localeCompare (case-insensitive ordering: 'a' before 'R').
    expect(files).toEqual(['a.ts', 'README.md', 'src/b.ts'])
    expect(calls[0]).toContain('git ls-files')
  })
})

describe('RepoService.readFile', () => {
  it('quotes the path safely', async () => {
    const { repo, calls } = makeRepo(() => ({ stdout: 'contents' }))
    const out = await repo.readFile("weird name's.ts")
    expect(out).toBe('contents')
    expect(calls[0]).toBe(`cat -- 'weird name'\\''s.ts'`)
  })
})

describe('RepoService.status', () => {
  const porcelain = '## main...origin/main [ahead 1]\n M a.txt\nA  c.txt\n?? b.txt\nMM d.txt\n'
  const unstagedNum = '1\t0\ta.txt\n4\t2\td.txt\n'
  const stagedNum = '1\t0\tc.txt\n3\t1\td.txt\n'

  function route(cmd: string): Partial<ExecResult> {
    if (cmd.includes('--cached --numstat')) return { stdout: stagedNum }
    if (cmd.includes('diff --numstat')) return { stdout: unstagedNum }
    if (cmd.includes('status --porcelain')) return { stdout: porcelain }
    return { stdout: '' }
  }

  it('parses the branch name (ignoring upstream/ahead info)', async () => {
    const { repo } = makeRepo(route)
    const st = await repo.status()
    expect(st.branch).toBe('main')
  })

  it('separates staged from unstaged/untracked with numstat counts', async () => {
    const { repo } = makeRepo(route)
    const st = await repo.status()

    const staged = Object.fromEntries(st.staged.map(f => [f.path, f]))
    const unstaged = Object.fromEntries(st.unstaged.map(f => [f.path, f]))

    // A staged add
    expect(staged['c.txt']).toMatchObject({ staged: true, index: 'A', added: 1, deleted: 0 })
    // Modified in worktree only
    expect(unstaged['a.txt']).toMatchObject({ unstaged: true, work: 'M', added: 1, deleted: 0 })
    // Untracked
    expect(unstaged['b.txt']).toMatchObject({ untracked: true })
    // Staged AND unstaged (MM) appears in both groups
    expect(staged['d.txt']).toMatchObject({ staged: true, added: 3, deleted: 1 })
    expect(unstaged['d.txt']).toMatchObject({ unstaged: true, added: 4, deleted: 2 })
  })

  it('handles a fresh repo with no commits', async () => {
    const { repo } = makeRepo(() => ({ stdout: '## No commits yet on main\n?? x.txt\n' }))
    const st = await repo.status()
    expect(st.branch).toBe('main')
    expect(st.unstaged[0]).toMatchObject({ path: 'x.txt', untracked: true })
  })
})

describe('RepoService.log', () => {
  it('parses hash/short/subject and strips HEAD-> from refs', async () => {
    const sep = '\x1f'
    const line = ['abc123def', 'abc123d', 'initial commit', 'HEAD -> main, origin/main, tag: v1'].join(sep)
    const { repo } = makeRepo(() => ({ stdout: line + '\n' }))
    const commits = await repo.log(10)
    expect(commits).toHaveLength(1)
    expect(commits[0]).toMatchObject({ hash: 'abc123def', short: 'abc123d', subject: 'initial commit' })
    expect(commits[0].refs).toEqual(['main', 'origin/main', 'tag: v1'])
  })

  it('returns an empty list for no output', async () => {
    const { repo } = makeRepo(() => ({ stdout: '' }))
    expect(await repo.log()).toEqual([])
  })
})

describe('RepoService mutations', () => {
  it('stage / unstage send quoted git commands', async () => {
    const { repo, calls } = makeRepo(() => ({ stdout: '' }))
    await repo.stage('src/a.ts')
    await repo.unstage('src/a.ts')
    expect(calls[0]).toBe(`git add -- 'src/a.ts'`)
    expect(calls[1]).toBe(`git reset -q HEAD -- 'src/a.ts'`)
  })

  it('commit runs git commit and returns the new short hash', async () => {
    const { repo, calls } = makeRepo((cmd) =>
      cmd.startsWith('git rev-parse') ? { stdout: 'deadbee\n' } : { stdout: '' },
    )
    const short = await repo.commit('feat: thing')
    expect(short).toBe('deadbee')
    expect(calls[0]).toBe(`git commit -m 'feat: thing'`)
  })
})

describe('RepoService error handling', () => {
  it('throws with stderr when a command exits non-zero', async () => {
    const { repo } = makeRepo(() => ({ stderr: 'fatal: not a git repository', code: 128 }))
    await expect(repo.listFiles()).rejects.toThrow('not a git repository')
  })
})
