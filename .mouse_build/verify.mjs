// Mouse visual verification harness.
// Boots the production build via `vite preview`, opens the app in demo mode,
// drives each module view, captures screenshots into .mouse_build/shots/, and
// fails loudly on console errors or missing UI. Run: node .mouse_build/verify.mjs
import { chromium } from 'playwright'
import { spawn } from 'node:child_process'
import { mkdirSync } from 'node:fs'
import { setTimeout as sleep } from 'node:timers/promises'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'

const __dir = dirname(fileURLToPath(import.meta.url))
const ROOT = join(__dir, '..')
const SHOTS = join(__dir, 'shots')
mkdirSync(SHOTS, { recursive: true })

const PORT = 4319
const BASE = `http://127.0.0.1:${PORT}`

function startPreview() {
  const p = spawn('npx', ['vite', 'preview', '--port', String(PORT), '--strictPort', '--host', '127.0.0.1'], {
    cwd: ROOT, stdio: ['ignore', 'pipe', 'pipe'], env: { ...process.env },
  })
  p.stdout.on('data', () => {})
  p.stderr.on('data', () => {})
  return p
}

async function waitForServer(url, tries = 60) {
  for (let i = 0; i < tries; i++) {
    try { const r = await fetch(url); if (r.ok) return true } catch {}
    await sleep(250)
  }
  throw new Error('preview server did not come up')
}

const VIEWS = ['code', 'files', 'changes', 'graph', 'terminal', 'agent']
const fails = []

const preview = startPreview()
let browser
try {
  await waitForServer(BASE)
  browser = await chromium.launch()
  const page = await browser.newPage({ viewport: { width: 430, height: 932 }, deviceScaleFactor: 2 })

  const consoleErrors = []
  page.on('console', (m) => { if (m.type() === 'error') consoleErrors.push(m.text()) })
  page.on('pageerror', (e) => consoleErrors.push('pageerror: ' + e.message))

  await page.goto(`${BASE}/?demo=1`, { waitUntil: 'networkidle' })
  await sleep(800)

  // The app shell must exist with module cards + bottom bar.
  const hasApp = await page.locator('.app').count()
  if (!hasApp) fails.push('no .app shell rendered')
  const hasStack = await page.locator('.module-stack').count()
  if (!hasStack) fails.push('no .module-stack rendered')
  const hasBottom = await page.locator('.bottom-bar').count()
  if (!hasBottom) fails.push('no .bottom-bar rendered')
  const modules = await page.locator('.module').count()
  if (modules < 2) fails.push(`expected >=2 modules, got ${modules}`)

  await page.screenshot({ path: join(SHOTS, '00-initial.png') })

  // Drive the first module through every view by setting the track transform,
  // mounting each view, and snapshotting it. We use the view-slot data attr.
  for (let i = 0; i < VIEWS.length; i++) {
    const v = VIEWS[i]
    // Properly mount + navigate to this view via the demo hook.
    await page.evaluate((view) => {
      (window).__mouseStack?.showViewIn(view, 0)
    }, v)
    await sleep(500)
    const slot = page.locator(`.module .view-slot[data-view="${v}"]`).first()
    const present = await slot.count()
    if (!present) { fails.push(`view-slot ${v} missing`); continue }
    await page.screenshot({ path: join(SHOTS, `${String(i + 1).padStart(2, '0')}-${v}.png`) })
  }

  // Assert each non-terminal view actually has its content mounted.
  await page.evaluate(() => (window).__mouseStack?.showViewIn('files', 0))
  await sleep(400)
  if (!(await page.locator('.view-files .file-item').count())) fails.push('files view did not mount items')
  await page.evaluate(() => (window).__mouseStack?.showViewIn('graph', 0))
  await sleep(400)
  if (!(await page.locator('.graph-label').count())) fails.push('graph view did not mount header')
  if (!(await page.locator('.graph-dot').count())) fails.push('graph view did not mount dots')
  await page.evaluate(() => (window).__mouseStack?.showViewIn('code', 0))
  await sleep(300)

  // Regression guard: the highlighter must not leak its own span markup as text.
  const codeText = await page.locator('.code-scroll').first().innerText().catch(() => '')
  if (/class="tag"|class="attr"|class="str"/.test(codeText)) {
    fails.push('code highlighter leaked span markup into visible text')
  }

  // Specific content assertions matching the sketches.
  const checks = [
    ['.code-scroll',        'code editor body'],
    ['.view-files .file-item', 'file tree items'],
    ['.changes-label',      'CHANGES header'],
    ['.commit-btn',         'yellow Commit button'],
    ['.graph-label',        'GRAPH header'],
    ['.graph-dot',          'git graph dots'],
    ['.composer-input',     'composer input'],
    ['.mic-btn',            'mic button'],
  ]
  for (const [sel, label] of checks) {
    const n = await page.locator(sel).count()
    if (!n) fails.push(`missing ${label} (${sel})`)
  }

  // Submit a task to spawn an agent; the agent terminal must appear.
  await page.locator('.composer-input').fill('Add a feature to the README')
  await page.locator('.composer-input').press('Enter')
  await sleep(2500)
  const xterm = await page.locator('.xterm').count()
  if (!xterm) fails.push('no xterm terminal after spawning agent')
  const agentBar = await page.locator('.agent-view-bar').count()
  if (!agentBar) fails.push('no agent status bar after spawning agent')
  await page.screenshot({ path: join(SHOTS, '07-agent-live.png') })

  if (consoleErrors.length) {
    // xterm/webgl noise in headless is tolerated; surface everything else.
    const real = consoleErrors.filter(e => !/webgl|WebGL|AudioContext/i.test(e))
    if (real.length) fails.push('console errors:\n  ' + real.join('\n  '))
  }
} catch (e) {
  fails.push('harness exception: ' + (e?.stack || e?.message || String(e)))
} finally {
  if (browser) await browser.close()
  preview.kill('SIGTERM')
}

if (fails.length) {
  console.log('VERIFY: FAIL')
  for (const f of fails) console.log(' - ' + f)
  process.exit(1)
} else {
  console.log('VERIFY: PASS — all views rendered, screenshots in .mouse_build/shots/')
  process.exit(0)
}
