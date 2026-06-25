import { OnDeviceFS } from './OnDeviceFS.ts'

export interface ChangedFile {
  path: string
  status: 'modified' | 'added' | 'deleted'
  added: number    // lines added vs baseline
  removed: number  // lines removed vs baseline
}

type Listener = () => void

/**
 * Workspace — the live model the panels read from. Wraps the on-device
 * filesystem and tracks a baseline snapshot so it can report real changes
 * (added/modified/deleted) the way a git status would, with per-file line deltas.
 *
 * Everything here is real: file contents come from OnDeviceFS, edits write back,
 * and the change set is computed by diffing current content against the baseline
 * captured at the last commit (or at fork time).
 */
export class Workspace {
  private fs: OnDeviceFS
  private baseline = new Map<string, string>()   // path -> content at last commit
  private listeners: Listener[] = []
  name: string

  private constructor(fs: OnDeviceFS, name: string) {
    this.fs = fs
    this.name = name
  }

  static async open(fs: OnDeviceFS, name: string): Promise<Workspace> {
    const ws = new Workspace(fs, name)
    await ws.captureBaseline()
    return ws
  }

  onChange(fn: Listener) { this.listeners.push(fn) }
  private emit() { this.listeners.forEach(f => f()) }

  /** Snapshot current files as the committed baseline (called after a commit). */
  async captureBaseline(): Promise<void> {
    this.baseline.clear()
    for (const path of await this.fs.list()) {
      this.baseline.set(path, (await this.fs.read(path)) ?? '')
    }
  }

  async listFiles(): Promise<string[]> {
    return this.fs.list()
  }

  async read(path: string): Promise<string> {
    return (await this.fs.read(path)) ?? ''
  }

  async write(path: string, content: string): Promise<void> {
    await this.fs.write(path, content)
    this.emit()
  }

  async remove(path: string): Promise<void> {
    await this.fs.remove(path)
    this.emit()
  }

  /** Real change set: diff current files against the committed baseline. */
  async changes(): Promise<ChangedFile[]> {
    const current = new Set(await this.fs.list())
    const out: ChangedFile[] = []

    for (const path of current) {
      const now = (await this.fs.read(path)) ?? ''
      if (!this.baseline.has(path)) {
        out.push({ path, status: 'added', added: lineCount(now), removed: 0 })
      } else {
        const base = this.baseline.get(path)!
        if (base !== now) {
          const [a, r] = lineDelta(base, now)
          out.push({ path, status: 'modified', added: a, removed: r })
        }
      }
    }
    for (const path of this.baseline.keys()) {
      if (!current.has(path)) {
        out.push({ path, status: 'deleted', added: 0, removed: lineCount(this.baseline.get(path)!) })
      }
    }
    return out.sort((x, y) => x.path.localeCompare(y.path))
  }

  /** "Commit": fold current state into the baseline so changes reset to empty. */
  async commit(): Promise<number> {
    const n = (await this.changes()).length
    await this.captureBaseline()
    this.emit()
    return n
  }
}

function lineCount(s: string): number {
  if (s === '') return 0
  return s.split('\n').length
}

/** Crude added/removed line counts (set difference on lines, like a coarse diff). */
function lineDelta(base: string, now: string): [number, number] {
  const b = base.split('\n')
  const n = now.split('\n')
  const bSet = new Map<string, number>()
  for (const l of b) bSet.set(l, (bSet.get(l) ?? 0) + 1)
  const nSet = new Map<string, number>()
  for (const l of n) nSet.set(l, (nSet.get(l) ?? 0) + 1)
  let added = 0, removed = 0
  for (const [l, c] of nSet) added += Math.max(0, c - (bSet.get(l) ?? 0))
  for (const [l, c] of bSet) removed += Math.max(0, c - (nSet.get(l) ?? 0))
  return [added, removed]
}
