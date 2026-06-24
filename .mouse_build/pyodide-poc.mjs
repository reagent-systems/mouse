// Proof-of-concept: load Pyodide in headless Chromium and run Python, capturing
// streamed stdout. If this passes, the in-app "Python script that looks like a
// terminal" architecture is viable. Run: node .mouse_build/pyodide-poc.mjs
import { chromium } from 'playwright'
import { setTimeout as sleep } from 'node:timers/promises'

const PY_VERSION = '314.0.0'
const html = `<!doctype html><html><head><meta charset="utf-8"></head>
<body><script type="module">
  window.__out = []
  const { loadPyodide } = await import('https://cdn.jsdelivr.net/pyodide/v${PY_VERSION}/full/pyodide.mjs')
  const py = await loadPyodide({
    stdout: (s) => { window.__out.push(s); },
    stderr: (s) => { window.__out.push('ERR:' + s); },
  })
  window.__pyready = true
  // Run a script that prints multiple lines + does a tiny computation.
  await py.runPythonAsync(\`
import sys
for i in range(3):
    print(f"line {i}")
print("sum", sum(range(10)))
\`)
  window.__done = true
</script></body></html>`

const browser = await chromium.launch()
const page = await browser.newPage()
const errors = []
page.on('pageerror', e => errors.push(e.message))
page.on('console', m => { if (m.type() === 'error') errors.push('console:' + m.text()) })

await page.setContent(html, { waitUntil: 'domcontentloaded' })
// Pyodide download+init can take a while on first load.
try {
  await page.waitForFunction('window.__done === true', { timeout: 60000 })
} catch (e) {
  const ready = await page.evaluate(() => !!window.__pyready)
  console.log('FAIL: pyodide did not finish. __pyready=', ready, 'errors=', errors)
  await browser.close()
  process.exit(1)
}

const out = await page.evaluate(() => window.__out)
await browser.close()

const text = out.join('\n')
const ok = text.includes('line 0') && text.includes('line 2') && text.includes('sum 45')
console.log('--- captured stdout ---')
console.log(text)
console.log('-----------------------')
console.log(ok ? 'PYODIDE POC: PASS — Python ran + stdout streamed' : 'PYODIDE POC: FAIL — unexpected output')
process.exit(ok ? 0 : 1)
