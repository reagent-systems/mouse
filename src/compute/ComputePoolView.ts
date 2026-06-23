import { ComputePool } from './ComputePool.ts'
import type { PoolConfig, PoolState } from './ComputePool.ts'
import type { ShardResult } from './types.ts'

function esc(s: string): string {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
}

const CONNECTION_LABEL: Record<PoolState['connection'], string> = {
  disabled: 'Disabled',
  solo: 'Solo (no coordinator)',
  connecting: 'Connecting…',
  connected: 'Connected',
  error: 'Coordinator error',
}

/**
 * Beta control panel for the decentralized sharded WebGPU compute pool.
 * Shown as a dismissible overlay; copy is intentionally functional/status-only.
 */
export class ComputePoolView {
  el: HTMLElement
  private pool: ComputePool
  private statusEl!: HTMLElement
  private logEl!: HTMLElement
  private runBtn!: HTMLButtonElement
  private sizeSel!: HTMLSelectElement
  private unsub: (() => void) | null = null
  private onClose: () => void

  constructor(config: PoolConfig, onClose: () => void) {
    this.onClose = onClose
    this.pool = new ComputePool(config)
    this.el = document.createElement('div')
    this.el.className = 'compute-overlay'
    this.render()
    this.unsub = this.pool.onChange((s) => this.renderStatus(s))
    void this.pool.init()
  }

  private render() {
    this.el.innerHTML = `
      <div class="compute-panel glass">
        <div class="compute-header">
          <span class="compute-title">Compute Pool <span class="compute-badge">beta</span></span>
          <button class="compute-close" id="close-btn" aria-label="Close">✕</button>
        </div>
        <div class="compute-status" id="status"></div>
        <div class="compute-controls">
          <select class="compute-select" id="size">
            <option value="128">128 × 128</option>
            <option value="256" selected>256 × 256</option>
            <option value="512">512 × 512</option>
          </select>
          <button class="auth-btn compute-run" id="run">Run sharded job</button>
        </div>
        <div class="compute-log" id="log"></div>
      </div>
    `
    this.statusEl = this.el.querySelector('#status')!
    this.logEl = this.el.querySelector('#log')!
    this.runBtn = this.el.querySelector('#run') as HTMLButtonElement
    this.sizeSel = this.el.querySelector('#size') as HTMLSelectElement

    this.el.querySelector('#close-btn')!.addEventListener('click', () => this.close())
    this.runBtn.addEventListener('click', () => this.runDemo())
  }

  private renderStatus(s: PoolState) {
    const gpu = s.gpu.available
      ? `Available${s.gpu.description ? ` — ${esc(s.gpu.description)}` : ''}`
      : 'Unavailable'
    this.statusEl.innerHTML = `
      <div class="compute-row"><span>WebGPU</span><b class="${s.gpu.available ? 'ok' : 'bad'}">${gpu}</b></div>
      <div class="compute-row"><span>Pool</span><b>${CONNECTION_LABEL[s.connection]}</b></div>
      <div class="compute-row"><span>Workers</span><b>${(s.gpu.available ? 1 : 0) + s.peerCount} (${s.peerCount} peer${s.peerCount === 1 ? '' : 's'})</b></div>
      <div class="compute-row"><span>Node</span><b class="mono">${esc(s.nodeId)}</b></div>
    `
    if (!s.gpu.available) {
      this.runBtn.disabled = s.peerCount === 0
    }
  }

  private log(line: string) {
    const div = document.createElement('div')
    div.className = 'compute-log-line'
    div.textContent = line
    this.logEl.appendChild(div)
    this.logEl.scrollTop = this.logEl.scrollHeight
  }

  private async runDemo() {
    const size = parseInt(this.sizeSel.value, 10)
    this.runBtn.disabled = true
    this.runBtn.textContent = 'Running…'
    this.logEl.innerHTML = ''
    this.log(`Dispatching ${size}×${size} matmul in shards…`)

    const byWorker = new Map<string, number>()
    const onResult = (r: ShardResult) => {
      byWorker.set(r.computedBy, (byWorker.get(r.computedBy) ?? 0) + 1)
      this.log(`shard #${r.shardId} (rows ${r.rowStart}–${r.rowStart + r.rows}) ← ${r.computedBy} in ${r.ms.toFixed(1)}ms`)
    }

    try {
      const report = await this.pool.runDemo(size, onResult)
      this.log('─'.repeat(28))
      this.log(`Done: ${report.perShard.length} shards in ${report.totalMs.toFixed(1)}ms · ${report.gflops.toFixed(1)} GFLOP/s`)
      const split = [...byWorker.entries()].map(([id, n]) => `${id}:${n}`).join('  ')
      this.log(`Work split → ${split}`)
    } catch (e) {
      this.log(`Error: ${e instanceof Error ? e.message : String(e)}`)
    } finally {
      this.runBtn.disabled = false
      this.runBtn.textContent = 'Run sharded job'
    }
  }

  private close() {
    this.unsub?.()
    this.pool.destroy()
    this.el.remove()
    this.onClose()
  }
}
