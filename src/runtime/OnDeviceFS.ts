// On-device filesystem — a real, persistent file store that lives entirely on
// the phone/desktop, no server. Backed by OPFS (Origin Private File System) when
// available (iOS 16.4+ WKWebView, all modern browsers), with an in-memory +
// localStorage fallback so it always works, even in the test harness.
//
// "Fork files locally" means: copy a starter workspace (or an imported repo) into
// this store, then open the interface against it. Edits persist between launches.

export interface FileEntry {
  path: string          // e.g. "src/main.py"
  content: string
}

interface FSBackend {
  readonly kind: string
  list(): Promise<string[]>
  read(path: string): Promise<string | null>
  write(path: string, content: string): Promise<void>
  remove(path: string): Promise<void>
  clear(): Promise<void>
}

// ── OPFS backend (preferred; truly on-device, persistent) ──────────────────
class OpfsBackend implements FSBackend {
  readonly kind = 'opfs'
  private root: FileSystemDirectoryHandle

  private constructor(root: FileSystemDirectoryHandle) { this.root = root }

  static async create(): Promise<OpfsBackend | null> {
    try {
      const anyNav = navigator as any
      if (!anyNav.storage?.getDirectory) return null
      const root = await anyNav.storage.getDirectory()
      // Namespace under a subdir so we don't collide with other OPFS users.
      const dir = await root.getDirectoryHandle('mouse-workspace', { create: true })
      return new OpfsBackend(dir)
    } catch { return null }
  }

  private async dirFor(path: string, create: boolean): Promise<[FileSystemDirectoryHandle, string]> {
    const parts = path.split('/').filter(Boolean)
    const file = parts.pop()!
    let dir = this.root
    for (const p of parts) dir = await dir.getDirectoryHandle(p, { create })
    return [dir, file]
  }

  async list(): Promise<string[]> {
    const out: string[] = []
    const walk = async (dir: FileSystemDirectoryHandle, prefix: string) => {
      // @ts-ignore - async iterator on directory handle
      for await (const [name, handle] of dir.entries()) {
        const p = prefix ? `${prefix}/${name}` : name
        if (handle.kind === 'directory') await walk(handle, p)
        else out.push(p)
      }
    }
    await walk(this.root, '')
    return out.sort()
  }

  async read(path: string): Promise<string | null> {
    try {
      const [dir, file] = await this.dirFor(path, false)
      const fh = await dir.getFileHandle(file)
      const f = await fh.getFile()
      return await f.text()
    } catch { return null }
  }

  async write(path: string, content: string): Promise<void> {
    const [dir, file] = await this.dirFor(path, true)
    const fh = await dir.getFileHandle(file, { create: true })
    const w = await fh.createWritable()
    await w.write(content)
    await w.close()
  }

  async remove(path: string): Promise<void> {
    try {
      const [dir, file] = await this.dirFor(path, false)
      await dir.removeEntry(file)
    } catch { /* ignore */ }
  }

  async clear(): Promise<void> {
    // @ts-ignore
    for await (const [name] of this.root.entries()) {
      await this.root.removeEntry(name, { recursive: true }).catch(() => {})
    }
  }
}

// ── Fallback backend (in-memory mirrored to localStorage) ──────────────────
class MemBackend implements FSBackend {
  readonly kind = 'memory'
  private key = 'mouse_ondevice_fs'
  private map: Record<string, string>

  constructor() {
    let init: Record<string, string> = {}
    try { init = JSON.parse(localStorage.getItem(this.key) ?? '{}') } catch { /* ignore */ }
    this.map = init
  }
  private persist() { try { localStorage.setItem(this.key, JSON.stringify(this.map)) } catch { /* ignore */ } }

  async list() { return Object.keys(this.map).sort() }
  async read(path: string) { return this.map[path] ?? null }
  async write(path: string, content: string) { this.map[path] = content; this.persist() }
  async remove(path: string) { delete this.map[path]; this.persist() }
  async clear() { this.map = {}; this.persist() }
}

// ── Public façade ──────────────────────────────────────────────────────────
export class OnDeviceFS {
  private backend: FSBackend
  private constructor(backend: FSBackend) { this.backend = backend }

  static async open(): Promise<OnDeviceFS> {
    const opfs = await OpfsBackend.create()
    return new OnDeviceFS(opfs ?? new MemBackend())
  }

  get kind() { return this.backend.kind }

  list() { return this.backend.list() }
  read(path: string) { return this.backend.read(path) }
  write(path: string, content: string) { return this.backend.write(path, content) }
  remove(path: string) { return this.backend.remove(path) }
  clear() { return this.backend.clear() }

  /** True if a workspace already exists on this device. */
  async hasWorkspace(): Promise<boolean> {
    return (await this.backend.list()).length > 0
  }

  /** Fork a set of starter files into the on-device store (skips existing unless overwrite). */
  async forkFiles(files: FileEntry[], overwrite = false): Promise<number> {
    let n = 0
    for (const f of files) {
      if (!overwrite && (await this.backend.read(f.path)) !== null) continue
      await this.backend.write(f.path, f.content)
      n++
    }
    return n
  }
}
