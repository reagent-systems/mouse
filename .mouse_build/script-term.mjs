// Focused harness: prove the in-app ScriptTerminal actually runs Python (Pyodide)
// and streams output into the xterm widget. Boots the built app in demo mode,
// navigates to the 'script' view, clicks the "Python REPL" bundle, and asserts
// the known output text appears. Run: node .mouse_build/script-term.mjs
import { chromium } from 'playwright'
import { spawn } from 'node:child_process'
import { setTimeout as sleep } from 'node:timers/promises'
import { mkdirSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'

const __dir = dirname(fileURLToPath(import.meta.url))
const ROOT = join(__dir, '..')
const SHOTS = join(__dir, 'shots')
mkdirSync(SHOTS, { recursive: true })
const PORT = 4321
const BASE = `http://127.0.0.1:${PORT}`

function startPreview() {
  const p = spawn('npx', ['vite', 'preview', '--port', String(PORT), '--strictPort', '--host', '127.0.0.1'],
    { cwd: ROOT, stdio: ['ignore', 'pipe', 'pipe'] })
  p.stdout.on('data', () => {}); p.stderr.on('data', () => {})
  return p
}
async function waitForServer(url, tries = 80) {
  for (let i = 0; i < tries; i++) { try { const r = await fetch(url); if (r.ok) return } catch {} await sleep(250) }
  throw new Error('preview did not start')
}

const fails = []
const preview = startPreview()
let browser
try {
  await waitForServer(BASE)
  browser = await chromium.launch()
  const page = await browser.newPage({ viewport: { width: 430, height: 932 }, deviceScaleFactor: 2 })
  const errs = []
  page.on('pageerror', e => errs.push(e.message))

  await page.goto(`${BASE}/?demo=1`, { waitUntil: 'networkidle' })
  await sleep(900)
  // Navigate the first module to the script view.
  await page.evaluate(() => (window).__mouseStack?.showViewIn('script', 0))
  await sleep(600)
  if (!(await page.locator('.view-scriptterm').count())) fails.push('script terminal view did not render')
  if (!(await page.locator('.scriptterm-chip').count())) fails.push('no bundle launcher chips')
  await page.screenshot({ path: join(SHOTS, 'st-01-launcher.png') })

  // Click the "Python REPL" bundle (2nd chip) and wait for Pyodide to run.
  const chips = page.locator('.scriptterm-chip')
  const n = await chips.count()
  let clicked = false
  for (let i = 0; i < n; i++) {
    const t = await chips.nth(i).innerText()
    if (/REPL/i.test(t)) { await chips.nth(i).click(); clicked = true; break }
  }
  if (!clicked && n) { await chips.first().click(); clicked = true }
  if (!clicked) fails.push('could not click a bundle chip')

  // Pyodide first-load can take a while; poll the xterm text for known output.
  let seen = ''
  for (let i = 0; i < 80; i++) {
    await sleep(1000)
    seen = await page.locator('.view-scriptterm .xterm').first().innerText().catch(() => '')
    if (/Primes < 30|Sum of first 100 squares|Python \d/.test(seen)) break
  }
  await page.screenshot({ path: join(SHOTS, 'st-02-ran.png') })
  if (!/Primes < 30|Sum of first 100 squares|Python \d/.test(seen)) {
    fails.push('Pyodide output not found in script terminal. Captured:\n' + seen.slice(0, 400))
  }

  if (errs.filter(e => !/webgl|WebGL/i.test(e)).length) {
    fails.push('page errors:\n  ' + errs.join('\n  '))
  }
} catch (e) {
  fails.push('exception: ' + (e?.stack || e?.message || String(e)))
} finally {
  if (browser) await browser.close()
  preview.kill('SIGTERM')
}

if (fails.length) { console.log('SCRIPT-TERM: FAIL'); fails.forEach(f => console.log(' - ' + f)); process.exit(1) }
else { console.log('SCRIPT-TERM: PASS — Pyodide ran in-app and streamed to xterm'); process.exit(0) }
