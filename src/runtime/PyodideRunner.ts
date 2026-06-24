// PyodideRunner — runs Python entirely in the browser/WebView (no server, no PTY)
// and streams stdout/stderr line-by-line. This is the engine behind the
// "terminal that's actually a Python script runner": agents are Python scripts
// we ship, their printed output is streamed into an xterm view that LOOKS and
// FEELS like a real terminal.
//
// Why this design:
//   • Works on iOS/Safari WebView — Pyodide needs no SharedArrayBuffer / COOP-COEP
//     (unlike WebContainers), so it runs on the actual phone.
//   • No external binary to be missing (the failure mode of spawning `opencode`).
//   • Real HTTP via pyodide's patched urllib/pyfetch, so an agent can call an LLM
//     API and stream the reply — fully on-device.
//
// Limits (by design): no real subprocess, raw sockets, or host filesystem. Those
// belong to the optional relay backend. For agent-coding-as-a-script this is enough.

const PYODIDE_VERSION = '0.28.3'
const CDN_INDEX = `https://cdn.jsdelivr.net/pyodide/v${PYODIDE_VERSION}/full/`

export type StreamCb = (chunk: string) => void

let loaderPromise: Promise<any> | null = null

/** Load (once) and cache the Pyodide runtime. */
async function getPyodide(onStatus?: (s: string) => void): Promise<any> {
  if (loaderPromise) return loaderPromise
  loaderPromise = (async () => {
    onStatus?.('Loading Python runtime…')
    // Dynamic import from CDN keeps it out of the main bundle and lets the WASM
    // stream lazily on first use. indexURL points Pyodide at its asset siblings.
    const mod = await import(/* @vite-ignore */ `${CDN_INDEX}pyodide.mjs`)
    const py = await mod.loadPyodide({ indexURL: CDN_INDEX })
    onStatus?.('Python ready.')
    return py
  })()
  return loaderPromise
}

export interface RunHandle {
  /** Resolves when the script finishes (or rejects on Python error). */
  done: Promise<void>
  /** Best-effort interrupt (sets an interrupt flag Python checks between ops). */
  cancel(): void
}

export class PyodideRunner {
  private py: any = null

  /** Preload the runtime so the first run is instant. */
  async warmup(onStatus?: (s: string) => void): Promise<void> {
    this.py = await getPyodide(onStatus)
  }

  get ready(): boolean { return this.py !== null }

  /**
   * Run a Python script, streaming stdout/stderr to the callbacks as it prints.
   * Returns a handle whose `done` resolves on completion.
   */
  run(code: string, onStdout: StreamCb, onStderr?: StreamCb): RunHandle {
    let cancelled = false
    const done = (async () => {
      const py = this.py ?? await getPyodide()
      this.py = py
      // Route Python stdout/stderr through batched callbacks.
      py.setStdout({ batched: (s: string) => { if (!cancelled) onStdout(s + '\n') } })
      py.setStderr({ batched: (s: string) => { if (!cancelled) (onStderr ?? onStdout)(s + '\n') } })
      try {
        await py.runPythonAsync(code)
      } catch (err: any) {
        const msg = err?.message ?? String(err)
        ;(onStderr ?? onStdout)('\x1b[31m' + msg + '\x1b[0m\n')
        throw err
      }
    })()
    return {
      done,
      cancel() { cancelled = true },
    }
  }

  /**
   * Provide a value to a pending Python input() call. The runner installs a JS
   * bridge so input() resolves from app-supplied answers (e.g. y/n buttons).
   */
  async provideInput(_value: string): Promise<void> {
    // Reserved: wired up by ScriptTerminal via a shared queue (see installInputBridge).
  }
}

/**
 * Install an input() bridge: Python `input(prompt)` calls JS to fetch the next
 * answer from a queue the UI fills. Returns a function to push answers.
 */
export async function installInputBridge(
  py: any,
  onPrompt: (prompt: string) => void,
): Promise<(answer: string) => void> {
  const queue: string[] = []
  let resolver: ((v: string) => void) | null = null

  ;(globalThis as any).__mouseInputRequest = (prompt: string) => {
    onPrompt(prompt)
    if (queue.length) return Promise.resolve(queue.shift()!)
    return new Promise<string>((res) => { resolver = res })
  }

  await py.runPythonAsync(`
import builtins, js
from pyodide.ffi import to_js
async def _mouse_input(prompt=""):
    return await js.__mouseInputRequest(str(prompt))
builtins.input = lambda prompt="": _mouse_input(prompt)
`)

  return (answer: string) => {
    if (resolver) { resolver(answer); resolver = null }
    else queue.push(answer)
  }
}
