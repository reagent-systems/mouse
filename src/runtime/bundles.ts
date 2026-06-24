// Prepackaged script bundles — the launcher presets the user taps to run.
// Each bundle is a Python program that streams output, so it renders in the
// script-terminal exactly like a live agent/terminal session. Because we ship
// these, they can never be "missing" (the failure mode of spawning opencode).

export interface ScriptBundle {
  id: string
  title: string
  subtitle: string
  icon: string
  /** Python source. `__TASK__` is replaced with the user's composer text. */
  code: string
}

/** A scripted "agent" that narrates planning + actions like a coding agent. */
const AGENT_DEMO = `
import asyncio

TASK = """__TASK__"""

print("\\x1b[32muser@mouse\\x1b[0m:\\x1b[34m~/project\\x1b[0m % agent")
print("\\x1b[2mThinking…\\x1b[0m")
await asyncio.sleep(0.4)
print(f"\\x1b[36m> Read task:\\x1b[0m {TASK[:60]}")
await asyncio.sleep(0.4)
print("\\x1b[36m> Grepped codebase for relevant files\\x1b[0m")
await asyncio.sleep(0.4)
print("\\x1b[36m> Drafted a plan (3 steps)\\x1b[0m")
await asyncio.sleep(0.4)
print("\\x1b[2mThinking…\\x1b[0m")
await asyncio.sleep(0.5)
print("I can implement this. Proceed? [y/n]")
ans = await input("> ")
if str(ans).strip().lower().startswith("y"):
    print("\\x1b[32m✓ Applying changes…\\x1b[0m")
    await asyncio.sleep(0.5)
    print("\\x1b[32mTask complete.\\x1b[0m")
else:
    print("\\x1b[33mStopped. No changes made.\\x1b[0m")
`.trim()

/** A real on-device computation so users see it's genuine Python, not a mock. */
const PY_REPL_HELLO = `
import sys, platform
print(f"Python {sys.version.split()[0]} on {platform.system()} (in-browser via Pyodide)")
print("Sum of first 100 squares:", sum(i*i for i in range(1, 101)))
nums = [x for x in range(2, 30) if all(x % d for d in range(2, x))]
print("Primes < 30:", nums)
`.trim()

/**
 * An agent that ACTUALLY calls an LLM-style HTTP endpoint and streams the reply,
 * proving on-device network agents work. Uses pyodide.http (fetch under the
 * hood). The endpoint is overridable; defaults to a harmless echo service.
 */
const HTTP_AGENT = `
import json
from pyodide.http import pyfetch

TASK = """__TASK__"""
print("\\x1b[2mContacting model endpoint…\\x1b[0m")
try:
    resp = await pyfetch(
        "https://httpbin.org/post",
        method="POST",
        headers={"Content-Type": "application/json"},
        body=json.dumps({"prompt": TASK}),
    )
    data = await resp.json()
    sent = data.get("json", {}).get("prompt", "")
    print("\\x1b[36m> Round-trip OK. Echoed prompt:\\x1b[0m")
    for line in (sent or "(empty)").splitlines() or ["(empty)"]:
        print("  " + line)
    print("\\x1b[32m✓ Network agent path works on-device.\\x1b[0m")
except Exception as e:
    print(f"\\x1b[31mNetwork error: {e}\\x1b[0m")
`.trim()

export const BUNDLES: ScriptBundle[] = [
  { id: 'agent',  title: 'Run agent',  subtitle: 'Agent', icon: '∞', code: AGENT_DEMO },
  { id: 'repl',   title: 'Python REPL', subtitle: 'Python', icon: '🐍', code: PY_REPL_HELLO },
  { id: 'http',   title: 'HTTP agent', subtitle: 'HTTP', icon: '🌐', code: HTTP_AGENT },
]

export function bundleById(id: string): ScriptBundle | undefined {
  return BUNDLES.find(b => b.id === id)
}

/** Inject the user's task text into a bundle's code. */
export function withTask(code: string, task: string): string {
  // Escape triple-quotes/backslashes so the task can't break the Python string.
  const safe = task.replace(/\\/g, '\\\\').replace(/"""/g, '\\"\\"\\"')
  return code.replace('__TASK__', safe)
}
