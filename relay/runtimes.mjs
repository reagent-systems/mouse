// Agent runtime backends for the Mouse relay.
//
// A backend turns a logical session ("bash" or an "opencode" agent task) into a
// real PTY the relay multiplexes over the WebSocket. Backends are pluggable so
// the SAME relay+app works whether the agent runs as a local subprocess, inside
// an isolated Docker container, or (future) inside an NVIDIA OpenShell/NemoClaw
// sandbox. This is the seam that removes the hard dependency on GitHub Codespaces.
//
// Contract: createBackend(kind) -> { spawn(opts) -> IPty-like }.
// The returned object must expose: onData(cb), onExit(cb), write(data),
// resize(cols,rows), kill().
//
// Selection (env MOUSE_RUNTIME):
//   process  (default) — pty.spawn on the relay host. Zero dependencies.
//   docker             — pty.spawn("docker","run -it <image> <cmd>"). Isolated.
//   openshell          — reserved seam for NVIDIA OpenShell/NemoClaw sandbox
//                        (`nemoclaw run …`); falls back with a clear message until
//                        the CLI is present so the relay never hard-crashes.
import pty from 'node-pty'

const HOME = process.env.HOME ?? '/workspaces'
const SHELL = process.env.SHELL ?? '/bin/bash'
const DOCKER_IMAGE = process.env.MOUSE_DOCKER_IMAGE ?? 'node:20-bookworm'
const WORKDIR = process.env.MOUSE_WORKDIR ?? HOME

/**
 * @typedef {Object} SpawnOpts
 * @property {'bash'|'opencode'} command
 * @property {string} [task]
 * @property {number} [cols]
 * @property {number} [rows]
 */

function baseEnv() {
  return { ...process.env, TERM: 'xterm-256color' }
}

/** Resolve the actual program + args for a logical command on the host. */
function resolveProgram(command) {
  if (command === 'opencode') return { file: 'opencode', args: [] }
  return { file: SHELL, args: ['-l'] }
}

function spawnProcess(opts) {
  const { file, args } = resolveProgram(opts.command)
  return pty.spawn(file, args, {
    name: 'xterm-256color',
    cols: opts.cols ?? 220,
    rows: opts.rows ?? 50,
    cwd: WORKDIR,
    env: baseEnv(),
  })
}

function spawnDocker(opts) {
  const { file, args } = resolveProgram(opts.command)
  // Run the same logical command inside a throwaway container, mounting the
  // working dir so the agent sees the project. -it gives it a TTY; node-pty
  // provides the outer PTY the app streams.
  const dockerArgs = [
    'run', '--rm', '-i', '-t',
    '-w', '/work',
    '-v', `${WORKDIR}:/work`,
    DOCKER_IMAGE,
    file, ...args,
  ]
  return pty.spawn('docker', dockerArgs, {
    name: 'xterm-256color',
    cols: opts.cols ?? 220,
    rows: opts.rows ?? 50,
    cwd: WORKDIR,
    env: baseEnv(),
  })
}

function spawnOpenShell(opts) {
  // Seam for NVIDIA OpenShell / NemoClaw. The CLI shape (per NemoClaw docs) is
  // roughly `nemoclaw run --agent <agent> -- <cmd>`. We don't assume it's
  // installed; if it isn't, surface a synthetic PTY that prints guidance instead
  // of crashing the relay. Replace the availability check + argv when wiring a
  // real NemoClaw host.
  const { file, args } = resolveProgram(opts.command)
  const nemoArgs = ['run', '--', file, ...args]
  try {
    return pty.spawn('nemoclaw', nemoArgs, {
      name: 'xterm-256color',
      cols: opts.cols ?? 220,
      rows: opts.rows ?? 50,
      cwd: WORKDIR,
      env: baseEnv(),
    })
  } catch (e) {
    // Fall back to a bash that explains the missing dependency, so the UX is a
    // clear message rather than a dead session.
    const msg = 'NVIDIA OpenShell/NemoClaw runtime not found on this host. '
      + 'Install it (https://github.com/NVIDIA/NemoClaw) or set MOUSE_RUNTIME=process. '
      + `(${e && e.message ? e.message : 'spawn failed'})`
    return pty.spawn(SHELL, ['-lc', `echo "${msg.replace(/"/g, '\\"')}"; exec ${SHELL} -l`], {
      name: 'xterm-256color',
      cols: opts.cols ?? 220,
      rows: opts.rows ?? 50,
      cwd: WORKDIR,
      env: baseEnv(),
    })
  }
}

const BACKENDS = {
  process: spawnProcess,
  docker: spawnDocker,
  openshell: spawnOpenShell,
}

/** Active runtime kind for this relay process. */
export function runtimeKind() {
  const k = (process.env.MOUSE_RUNTIME ?? 'process').toLowerCase()
  return BACKENDS[k] ? k : 'process'
}

/**
 * Spawn a session PTY using the active backend.
 * @param {SpawnOpts} opts
 */
export function spawnSession(opts) {
  const kind = runtimeKind()
  return BACKENDS[kind](opts)
}
