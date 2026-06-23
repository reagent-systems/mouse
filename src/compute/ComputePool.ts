import type { MatmulDims, PoolConnection, PoolRole, ShardResult, Worker } from './types.ts'
import { getGpuInfo, isWebGPUAvailable, randomMatrix, runMatmul } from './webgpu.ts'
import type { GpuInfo } from './webgpu.ts'
import { SignalingClient } from './signaling.ts'
import { PeerLink } from './peer.ts'
import { buildTasks, planShards, runJob } from './ShardScheduler.ts'
import type { JobReport } from './ShardScheduler.ts'

export interface PoolConfig {
  coordinatorUrl?: string
  poolId?: string
  shardRows?: number
}

export interface PoolState {
  connection: PoolConnection
  role: PoolRole
  gpu: GpuInfo
  peerCount: number
  nodeId: string
}

function randomId(): string {
  return Math.random().toString(36).slice(2, 10)
}

/**
 * Orchestrates a node's participation in the decentralized compute pool:
 * probes WebGPU, joins the coordinator, manages peer links, and runs sharded
 * jobs across every available worker (this GPU + connected peers).
 */
export class ComputePool {
  readonly nodeId = randomId()
  private config: Required<Pick<PoolConfig, 'poolId' | 'shardRows'>> & PoolConfig
  private signaling: SignalingClient | null = null
  private peers = new Map<string, PeerLink>()
  private listeners = new Set<(s: PoolState) => void>()

  private state: PoolState = {
    connection: 'disabled',
    role: 'idle',
    gpu: { available: false },
    peerCount: 0,
    nodeId: this.nodeId,
  }

  constructor(config: PoolConfig = {}) {
    this.config = { poolId: config.poolId ?? 'mouse-public-beta', shardRows: config.shardRows ?? 64, ...config }
  }

  getState(): PoolState { return this.state }

  onChange(fn: (s: PoolState) => void): () => void {
    this.listeners.add(fn)
    fn(this.state)
    return () => this.listeners.delete(fn)
  }

  private patch(p: Partial<PoolState>) {
    this.state = { ...this.state, ...p, peerCount: this.peers.size }
    this.listeners.forEach(fn => fn(this.state))
  }

  /** Probe the GPU and, if a coordinator is configured, join the pool. */
  async init(): Promise<void> {
    const gpu = await getGpuInfo()
    this.patch({ gpu })

    const url = this.config.coordinatorUrl
    if (!url) {
      // No coordinator configured — run as a single-node ("solo") pool.
      this.patch({ connection: 'solo' })
      return
    }

    this.patch({ connection: 'connecting' })
    this.signaling = new SignalingClient(url, this.config.poolId, this.nodeId)
    this.signaling.onMessage((msg) => this.onSignal(msg))
    try {
      await this.signaling.connect()
      this.patch({ connection: 'connected' })
    } catch {
      this.patch({ connection: 'error' })
    }
  }

  private onSignal(msg: import('./types.ts').SignalMessage) {
    switch (msg.type) {
      case 'peers':
        // We are the newcomer: initiate connections to everyone already here.
        for (const peerId of msg.peers) this.ensurePeer(peerId, true)
        break
      case 'peer_joined':
        // The newcomer will initiate to us; wait for their offer.
        this.ensurePeer(msg.nodeId, false)
        break
      case 'peer_left': {
        this.peers.get(msg.nodeId)?.close()
        this.peers.delete(msg.nodeId)
        this.patch({})
        break
      }
      case 'signal':
        if (msg.to === this.nodeId) {
          const link = this.ensurePeer(msg.from, false)
          void link.accept(msg.data)
        }
        break
    }
  }

  private ensurePeer(peerId: string, initiator: boolean): PeerLink {
    let link = this.peers.get(peerId)
    if (!link) {
      link = new PeerLink(peerId, this.signaling!, initiator)
      this.peers.set(peerId, link)
      this.patch({})
    }
    return link
  }

  /** This node's own GPU as a worker. */
  private selfWorker(): Worker {
    return {
      id: 'self',
      weight: 2,
      run: async (task) => {
        const t0 = performance.now()
        const c = await runMatmul(task.a, task.b, { m: task.rows, k: task.dims.k, n: task.dims.n })
        return {
          jobId: task.jobId, shardId: task.shardId, rowStart: task.rowStart,
          rows: task.rows, c, computedBy: 'self', ms: performance.now() - t0,
        }
      },
    }
  }

  workers(): Worker[] {
    const list: Worker[] = []
    if (isWebGPUAvailable()) list.push(this.selfWorker())
    list.push(...this.peers.values())
    return list
  }

  /** Run a matmul job sharded across all available workers. */
  async runSharded(
    a: Float32Array,
    b: Float32Array,
    dims: MatmulDims,
    onResult?: (r: ShardResult) => void,
  ): Promise<JobReport> {
    const workers = this.workers()
    if (workers.length === 0) throw new Error('No compute workers available (WebGPU unavailable and no peers)')
    this.patch({ role: 'requester' })
    const jobId = randomId()
    const plans = planShards(dims.m, this.config.shardRows)
    const tasks = buildTasks(jobId, a, b, dims, plans)
    try {
      return await runJob(dims, tasks, workers, onResult)
    } finally {
      this.patch({ role: 'idle' })
    }
  }

  /** Convenience demo: random square matmul, returns the report + GFLOP/s. */
  async runDemo(size = 256, onResult?: (r: ShardResult) => void): Promise<JobReport & { gflops: number }> {
    const a = randomMatrix(size * size)
    const b = randomMatrix(size * size)
    const report = await this.runSharded(a, b, { m: size, k: size, n: size }, onResult)
    const flops = 2 * size * size * size
    return { ...report, gflops: flops / (report.totalMs / 1000) / 1e9 }
  }

  destroy(): void {
    this.peers.forEach(p => p.close())
    this.peers.clear()
    this.signaling?.close()
    this.listeners.clear()
  }
}
