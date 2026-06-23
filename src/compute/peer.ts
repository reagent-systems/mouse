import type { MatmulDims, ShardResult, ShardTask, Worker } from './types.ts'
import type { SignalingClient } from './signaling.ts'
import { runMatmul } from './webgpu.ts'

const RTC_CONFIG: RTCConfiguration = {
  iceServers: [{ urls: 'stun:stun.l.google.com:19302' }],
}

interface PendingTask {
  resolve: (r: ShardResult) => void
  reject: (e: Error) => void
  task: ShardTask
  startedAt: number
}

/**
 * A WebRTC link to one peer. Acts as a remote {@link Worker}: shard tasks are
 * serialized over the data channel and the peer streams back the result slice.
 * Incoming tasks are computed locally with WebGPU and returned.
 */
export class PeerLink implements Worker {
  readonly id: string
  weight = 1
  private pc: RTCPeerConnection
  private channel: RTCDataChannel | null = null
  private signaling: SignalingClient
  private pending = new Map<string, PendingTask>()
  private ready: Promise<void>
  private markReady!: () => void

  constructor(peerId: string, signaling: SignalingClient, initiator: boolean) {
    this.id = peerId
    this.signaling = signaling
    this.pc = new RTCPeerConnection(RTC_CONFIG)
    this.ready = new Promise((res) => { this.markReady = res })

    this.pc.onicecandidate = (e) => {
      if (e.candidate) {
        signaling.send({ type: 'signal', from: signaling.nodeId, to: peerId, data: { candidate: e.candidate } })
      }
    }

    if (initiator) {
      this.channel = this.pc.createDataChannel('shards')
      this.setupChannel(this.channel)
      void this.makeOffer()
    } else {
      this.pc.ondatachannel = (e) => { this.channel = e.channel; this.setupChannel(e.channel) }
    }
  }

  private async makeOffer(): Promise<void> {
    const offer = await this.pc.createOffer()
    await this.pc.setLocalDescription(offer)
    this.signaling.send({ type: 'signal', from: this.signaling.nodeId, to: this.id, data: { sdp: offer } })
  }

  /** Feed a signaling payload (SDP/ICE) addressed to this peer. */
  async accept(data: any): Promise<void> {
    if (data.sdp) {
      await this.pc.setRemoteDescription(data.sdp)
      if (data.sdp.type === 'offer') {
        const answer = await this.pc.createAnswer()
        await this.pc.setLocalDescription(answer)
        this.signaling.send({ type: 'signal', from: this.signaling.nodeId, to: this.id, data: { sdp: answer } })
      }
    } else if (data.candidate) {
      try { await this.pc.addIceCandidate(data.candidate) } catch { /* ignore */ }
    }
  }

  private setupChannel(ch: RTCDataChannel): void {
    ch.binaryType = 'arraybuffer'
    ch.onopen = () => this.markReady()
    ch.onmessage = (e) => this.onMessage(e.data)
  }

  private onMessage(data: ArrayBuffer): void {
    const { header, payload } = decode(data)
    if (header.kind === 'task') {
      void this.computeAndReply(header, payload)
    } else if (header.kind === 'result') {
      const key = `${header.jobId}:${header.shardId}`
      const pending = this.pending.get(key)
      if (pending) {
        this.pending.delete(key)
        pending.resolve({
          jobId: header.jobId, shardId: header.shardId, rowStart: header.rowStart,
          rows: header.rows, c: payload, computedBy: this.id, ms: header.ms ?? 0,
        })
      }
    }
  }

  private async computeAndReply(header: any, payload: Float32Array): Promise<void> {
    const dims: MatmulDims = header.dims
    const aLen = header.rows * dims.k
    const a = payload.subarray(0, aLen)
    const b = payload.subarray(aLen)
    const t0 = performance.now()
    const c = await runMatmul(a, b, { m: header.rows, k: dims.k, n: dims.n })
    const ms = performance.now() - t0
    this.channel?.send(encode(
      { kind: 'result', jobId: header.jobId, shardId: header.shardId, rowStart: header.rowStart, rows: header.rows, ms },
      c,
    ))
  }

  async run(task: ShardTask): Promise<ShardResult> {
    await this.ready
    return new Promise((resolve, reject) => {
      const key = `${task.jobId}:${task.shardId}`
      this.pending.set(key, { resolve, reject, task, startedAt: performance.now() })
      const payload = new Float32Array(task.a.length + task.b.length)
      payload.set(task.a, 0)
      payload.set(task.b, task.a.length)
      this.channel?.send(encode(
        { kind: 'task', jobId: task.jobId, shardId: task.shardId, rowStart: task.rowStart, rows: task.rows, dims: task.dims },
        payload,
      ))
    })
  }

  close(): void {
    this.channel?.close()
    this.pc.close()
  }
}

// ── Wire framing: [4-byte header length][JSON header][Float32 payload] ──────

function encode(header: object, payload: Float32Array): ArrayBuffer {
  const headerBytes = new TextEncoder().encode(JSON.stringify(header))
  const buf = new ArrayBuffer(4 + headerBytes.byteLength + payload.byteLength)
  const view = new DataView(buf)
  view.setUint32(0, headerBytes.byteLength)
  new Uint8Array(buf, 4, headerBytes.byteLength).set(headerBytes)
  new Float32Array(buf, 4 + headerBytes.byteLength).set(payload)
  return buf
}

function decode(buf: ArrayBuffer): { header: any; payload: Float32Array } {
  const view = new DataView(buf)
  const headerLen = view.getUint32(0)
  const header = JSON.parse(new TextDecoder().decode(new Uint8Array(buf, 4, headerLen)))
  const payload = new Float32Array(buf, 4 + headerLen)
  return { header, payload }
}
