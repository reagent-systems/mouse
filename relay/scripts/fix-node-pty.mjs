#!/usr/bin/env node
/**
 * Postinstall: restore the executable bit on node-pty's `spawn-helper`.
 *
 * node-pty ships a prebuilt `spawn-helper` binary, but pnpm's content-addressable
 * store extracts prebuild files without the +x permission, so node-pty fails at
 * runtime with "posix_spawnp failed". This walks node_modules (hoisted or pnpm
 * virtual store) and chmods every spawn-helper it finds. Idempotent + safe.
 */
import { readdirSync, statSync, chmodSync } from 'node:fs'
import { join } from 'node:path'

function walk(dir, hits, depth = 0) {
  if (depth > 8) return
  let entries
  try { entries = readdirSync(dir, { withFileTypes: true }) } catch { return }
  for (const e of entries) {
    const full = join(dir, e.name)
    if (e.isDirectory()) {
      // Skip giant unrelated trees but follow node_modules / .pnpm.
      walk(full, hits, depth + 1)
    } else if (e.name === 'spawn-helper') {
      hits.push(full)
    }
  }
}

const roots = ['node_modules', '../node_modules']
const hits = []
for (const r of roots) walk(r, hits)
let fixed = 0
for (const h of hits) {
  try {
    const m = statSync(h).mode
    if (!(m & 0o111)) { chmodSync(h, m | 0o755); fixed++ }
  } catch { /* ignore */ }
}
console.log(`[mouse-relay postinstall] spawn-helper: ${hits.length} found, ${fixed} made executable`)
