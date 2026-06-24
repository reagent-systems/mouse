// Starter workspaces that "fork" onto the device. Picking one copies its files
// into OnDeviceFS, then the app opens the interface against them. Everything is
// local — no GitHub, no relay, no network needed to get to your interface.
import type { FileEntry } from './OnDeviceFS.ts'

export interface Starter {
  id: string
  title: string
  subtitle: string
  icon: string
  files: FileEntry[]
}

const PY_AGENT_FILES: FileEntry[] = [
  {
    path: 'README.md',
    content: `# Workspace
`,
  },
  {
    path: 'agent.py',
    content: `import asyncio

async def main(task: str):
    print(f"\\\\x1b[36m> Task:\\\\x1b[0m {task or '(none)'}")
    print("\\\\x1b[2mThinking…\\\\x1b[0m")
    await asyncio.sleep(0.4)
    print("\\\\x1b[32m✓ Done.\\\\x1b[0m")

await main(TASK if 'TASK' in dir() else "")
`,
  },
  {
    path: 'main.py',
    content: `print("Hello")
`,
  },
]

const EMPTY_FILES: FileEntry[] = [
  {
    path: 'main.py',
    content: `print("Hello")
`,
  },
]

export const STARTERS: Starter[] = [
  {
    id: 'agent',
    title: 'Agent starter',
    subtitle: 'Python agent + README',
    icon: '∞',
    files: PY_AGENT_FILES,
  },
  {
    id: 'blank',
    title: 'Blank workspace',
    subtitle: 'main.py',
    icon: '◆',
    files: EMPTY_FILES,
  },
]

export function starterById(id: string): Starter | undefined {
  return STARTERS.find(s => s.id === id)
}
