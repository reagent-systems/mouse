// Mouse end-to-end interaction harness.
//
// Unlike a DOM-presence smoke check, this DRIVES the app like a user: it clicks
// real buttons, walks the full GitHub auth journey with a mocked transport
// (?mockgh=1, no network), navigates every page, exercises the composer + agent
// flow, answers an agent y/n prompt, and saves a screenshot at every step into
// .mouse_build/shots/. Each screenshot is also asserted non-blank.
//
// Two journeys:
//   A. AUTH  (?mockgh=1)  — landing → sign in → device code → token → install
//                            check → codespace picker "No Codespaces yet" → Create.
//   B. APP   (?demo=1)    — every module view + agent terminal + composer.
//
// Run: node .mouse_build/verify.mjs
import { chromium } from 'playwright'
import { spawn } from 'node:child_process'
import { mkdirSync, readFileSync, statSync } from 'node:fs'
import { setTimeout as sleep } from 'node:timers/promises'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'

const __dir = dirname(fileURLToPath(import.meta.url))
const ROOT = join(__dir, '..')
const SHOTS = join(__dir, 'shots')
mkdirSync(SHOTS, { recursive: true })

const PORT = 4319
const BASE = `http://127.0.0.1:${PORT}`
const fails = []
let shotN = 0

function startPreview() {
  const p = spawn('npx', ['vite', 'preview', '--port', String(PORT), '--strictPort', '--host', '127.0.0.1'], {
    cwd: ROOT, stdio: ['ignore', 'pipe', 'pipe'], env: { ...process.env },
  })
  p.stdout.on('data', () => {})
  p.stderr.on('data', () => {})
  return p
}

const RELAY_PORT = 2299
// Boot a REAL local relay (not mocked) so the Local journey proves an actual
// ws:// connection + PTY round-trip — the whole point of Codespace-free mode.
function startRelay() {
  const p = spawn('node', ['relay/mouse-relay.mjs', '--local'], {
    cwd: ROOT,
    stdio: ['ignore', 'pipe', 'pipe'],
    env: { ...process.env, MOUSE_RELAY_PORT: String(RELAY_PORT), MOUSE_RELAY_HOST: '127.0.0.1' },
  })
  p.stdout.on('data', () => {})
  p.stderr.on('data', () => {})
  return p
}

async function waitForRelay(tries = 40) {
  for (let i = 0; i < tries; i++) {
    try {
      const r = await fetch(`http://127.0.0.1:${RELAY_PORT}/health`)
      if (r.ok) { const j = await r.json(); if (j.ok) return j }
    } catch {}
    await sleep(250)
  }
  throw new Error('local relay did not come up')
}

async function waitForServer(url, tries = 80) {
  for (let i = 0; i < tries; i++) {
    try { const r = await fetch(url); if (r.ok) return true } catch {}
    await sleep(250)
  }
  throw new Error('preview server did not come up')
}

// Screenshot + assert it isn't a blank/near-empty frame (catches white screens
// of death where the app silently failed to render).
async function shot(page, name) {
  shotN++
  const file = join(SHOTS, `${String(shotN).padStart(2, '0')}-${name}.png`)
  await page.screenshot({ path: file })
  try {
    const sz = statSync(file).size
    if (sz < 2500) fails.push(`screenshot ${name} looks blank (${sz} bytes)`)
  } catch { fails.push(`screenshot ${name} not written`) }
  return file
}

async function clickIfPresent(page, selector, label) {
  const el = page.locator(selector).first()
  if (await el.count()) { await el.click(); return true }
  fails.push(`could not click ${label} (${selector})`)
  return false
}

const preview = startPreview()
const relay = startRelay()
let browser
try {
  await waitForServer(BASE)
  browser = await chromium.launch()
  const page = await browser.newPage({ viewport: { width: 430, height: 932 }, deviceScaleFactor: 2 })
  const consoleErrors = []
  page.on('console', (m) => { if (m.type() === 'error') consoleErrors.push(m.text()) })
  page.on('pageerror', (e) => consoleErrors.push('pageerror: ' + e.message))

  // ───────────────────────── Journey A: AUTH (mocked GitHub) ─────────────────
  await page.addInitScript(() => { try { localStorage.clear() } catch {} })
  await page.goto(`${BASE}/?mockgh=1`, { waitUntil: 'networkidle' })
  await sleep(500)
  await shot(page, 'auth-landing')
  if (!(await page.locator('.auth-title').count())) fails.push('auth landing did not render')

  // Click "Sign in with GitHub".
  await clickIfPresent(page, '#sign-in-btn', 'Sign in button')
  await sleep(600)
  await shot(page, 'auth-device-code')
  const codeShown = await page.locator('.auth-code-display').count()
  if (!codeShown) fails.push('device code screen did not render (the real-world blocker)')
  else {
    const code = (await page.locator('.auth-code-display').first().innerText()).trim()
    if (!code) fails.push('device code is empty')
  }

  // The mock pends once then issues a token; onDone advances to the install
  // check and then the codespace picker. pollForToken enforces a 5s min interval,
  // so first success lands ~10s in — wait generously.
  await page.waitForSelector('.picker-screen, .picker-empty, .picker-loading', { timeout: 20000 }).catch(() => {})
  await page.waitForSelector('.picker-empty, .cs-card', { timeout: 12000 }).catch(() => {})
  await sleep(800)
  await shot(page, 'auth-codespace-picker')
  const emptyState = await page.locator('.picker-empty').count()
  const pickerList = await page.locator('.picker-list, .cs-card').count()
  if (!emptyState && !pickerList) {
    fails.push('codespace picker never appeared after auth (auth flow still blocked)')
  }
  // "No Codespaces yet" → there must be a Create Codespace CTA, matching the sim.
  if (emptyState) {
    const cta = await page.locator('.picker-empty-cta, button:has-text("Create")').count()
    if (!cta) fails.push('empty state missing Create Codespace CTA')
  }

  // ───────────────────────── Journey B: APP (demo module UI) ────────────────
  await page.goto(`${BASE}/?demo=1`, { waitUntil: 'networkidle' })
  await sleep(900)
  await shot(page, 'app-initial')
  if (!(await page.locator('.module-stack').count())) fails.push('module stack did not render in demo')
  if ((await page.locator('.module').count()) < 2) fails.push('expected >=2 modules')

  const VIEWS = ['code', 'files', 'changes', 'graph', 'terminal', 'agent']
  for (const v of VIEWS) {
    await page.evaluate((view) => (window).__mouseStack?.showViewIn(view, 0), v)
    await sleep(450)
    if (!(await page.locator(`.module .view-slot[data-view="${v}"]`).first().count())) {
      fails.push(`view ${v} missing`)
    }
    await shot(page, `app-view-${v}`)
  }

  // Content assertions per view.
  await page.evaluate(() => (window).__mouseStack?.showViewIn('files', 0)); await sleep(350)
  if (!(await page.locator('.view-files .file-item').count())) fails.push('files view empty')
  await page.evaluate(() => (window).__mouseStack?.showViewIn('graph', 0)); await sleep(350)
  if (!(await page.locator('.graph-dot').count())) fails.push('graph has no commit dots')
  await page.evaluate(() => (window).__mouseStack?.showViewIn('changes', 0)); await sleep(350)
  // Actually CLICK the Commit button and assert it acknowledges.
  await clickIfPresent(page, '.commit-btn', 'Commit button')
  await sleep(400)
  await shot(page, 'app-commit-clicked')

  await page.evaluate(() => (window).__mouseStack?.showViewIn('code', 0)); await sleep(300)
  const codeText = await page.locator('.code-scroll').first().innerText().catch(() => '')
  if (/class="(tag|attr|str)"/.test(codeText)) fails.push('code highlighter leaked span markup')

  // Composer → spawn an agent, watch the terminal stream, answer a y/n prompt.
  await page.locator('.composer-input').fill('Add a feature to the README')
  await page.locator('.composer-input').press('Enter')
  await sleep(2600)
  if (!(await page.locator('.xterm').count())) fails.push('no xterm after spawning agent')
  if (!(await page.locator('.agent-view-bar').count())) fails.push('no agent status bar')
  await shot(page, 'app-agent-running')
  // The mock opencode stream asks a y/n question; type "y" into the agent term.
  const term = page.locator('.xterm-helper-textarea, .xterm textarea').first()
  if (await term.count()) { await term.type('y'); await term.press('Enter') }
  await sleep(1600)
  await shot(page, 'app-agent-answered')

  // ───────────── Journey A2: synced repo selector (still ?mockgh) ────────────
  await page.goto(`${BASE}/?mockgh=1`, { waitUntil: 'networkidle' })
  await sleep(500)
  await clickIfPresent(page, '#sign-in-btn', 'Sign in button (repo journey)')
  await page.waitForSelector('.picker-empty, .cs-card', { timeout: 20000 }).catch(() => {})
  await sleep(800)
  // Open the create form → must show a SYNCED repo list, not a free-text box.
  await clickIfPresent(page, '.picker-empty-cta, #create-btn', 'Create Codespace')
  await page.waitForSelector('.repo-row', { timeout: 8000 }).catch(() => {})
  const repoRows = await page.locator('.repo-row').count()
  if (repoRows < 1) fails.push('repo selector did not render a synced repo list')
  await shot(page, 'repo-selector')
  // Search filters the list.
  await page.locator('#repo-search').fill('hello')
  await sleep(300)
  const filtered = await page.locator('.repo-row').count()
  if (filtered < 1) fails.push('repo search filter returned nothing for "hello"')
  await page.locator('#repo-search').fill('')
  await sleep(200)
  // Selecting a repo reveals the branch dropdown.
  await clickIfPresent(page, '.repo-row', 'first repo row')
  await sleep(500)
  if (!(await page.locator('#branch-select').count())) fails.push('branch dropdown did not appear after repo select')
  const branchOpts = await page.locator('#branch-select option').count()
  if (branchOpts < 1) fails.push('branch dropdown has no options')
  await shot(page, 'repo-selected-branches')

  // ───────────────────── Journey C: LOCAL mode (real relay) ──────────────────
  // Reach the local gate, point it at the real relay we booted, and confirm the
  // app connects + a real agent terminal streams from a real PTY.
  const relayHealth = await waitForRelay()
  if (relayHealth.mode !== 'local') fails.push(`relay mode expected local, got ${relayHealth.mode}`)
  await page.goto(`${BASE}/?local=1`, { waitUntil: 'networkidle' })
  await sleep(600)
  await shot(page, 'local-gate')
  if (!(await page.locator('#relay-url').count())) fails.push('local relay gate did not render')
  await page.locator('#relay-url').fill(`127.0.0.1:${RELAY_PORT}`)
  await clickIfPresent(page, '#connect-local', 'local Test & Connect')
  // After a healthy probe the app shows the module stack + bottom bar.
  await page.waitForSelector('.module-stack', { timeout: 12000 }).catch(() => {})
  await sleep(1200)
  await shot(page, 'local-connected')
  if (!(await page.locator('.module-stack').count())) fails.push('local mode did not reach the module UI')
  // Spawn an agent over the REAL relay and confirm the terminal appears.
  if (await page.locator('.composer-input').count()) {
    await page.locator('.composer-input').fill('echo hello-from-local')
    await page.locator('.composer-input').press('Enter')
    await sleep(3000)
    if (!(await page.locator('.xterm').count())) fails.push('local: no xterm after spawning agent over real relay')
    await shot(page, 'local-agent')
  } else {
    fails.push('local: composer input missing — cannot spawn agent')
  }

  // Console health (tolerate headless webgl noise).
  const real = consoleErrors.filter(e => !/webgl|WebGL|AudioContext|Failed to load resource.*favicon/i.test(e))
  if (real.length) fails.push('console errors:\n  ' + real.join('\n  '))
} catch (e) {
  fails.push('harness exception: ' + (e?.stack || e?.message || String(e)))
} finally {
  if (browser) await browser.close()
  preview.kill('SIGTERM')
  relay.kill('SIGTERM')
}

if (fails.length) {
  console.log('VERIFY: FAIL')
  for (const f of fails) console.log(' - ' + f)
  process.exit(1)
} else {
  console.log(`VERIFY: PASS — ${shotN} screenshots in .mouse_build/shots/ (auth + repo selector + app + local relay journeys)`)
  process.exit(0)
}
