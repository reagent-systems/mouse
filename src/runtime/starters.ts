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
    content: `# My Mouse Workspace

This workspace lives **on your device** — forked locally, no server.
Edit files in the editor, run agents in the terminal. Everything persists
between launches via the on-device filesystem (OPFS).
`,
  },
  {
    path: 'agent.py',
    content: `"""A tiny on-device coding agent. Edit me — I run in the in-app terminal."""
import asyncio

async def main(task: str):
    print(f"\\x1b[36m> Task:\\x1b[0m {task or '(none)'}")
    print("\\x1b[2mThinking…\\x1b[0m")
    await asyncio.sleep(0.4)
    print("\\x1b[32m✓ This agent runs entirely on-device.\\x1b[0m")

# The runner injects the composer text as TASK.
await main(TASK if 'TASK' in dir() else "")
`,
  },
  {
    path: 'main.py',
    content: `print("Hello from your on-device workspace!")
print("Files here are stored locally and persist between sessions.")
`,
  },
]

const EMPTY_FILES: FileEntry[] = [
  {
    path: 'main.py',
    content: `print("New on-device workspace. Edit me and run.")
`,
  },
]

export const STARTERS: Starter[] = [
  {
    id: 'agent',
    title: 'Agent starter',
    subtitle: 'Python agent + README, ready to run',
    icon: '∞',
    files: PY_AGENT_FILES,
  },
  {
    id: 'blank',
    title: 'Blank workspace',
    subtitle: 'Just a main.py to start from',
    icon: '◆',
    files: EMPTY_FILES,
  },
]

export function starterById(id: string): Starter | undefined {
  return STARTERS.find(s => s.id === id)
}
