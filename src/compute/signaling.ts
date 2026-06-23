import type { SignalMessage } from './types.ts'

type Handler = (msg: SignalMessage) => void

/**
 * Thin WebSocket client for the compute-pool coordinator. The coordinator only
 * brokers membership + WebRTC handshakes; shard payloads never pass through it.
 */
export class SignalingClient {
  private ws: WebSocket | null = null
  private handlers = new Set<Handler>()
  private url: string
  readonly nodeId: string
  readonly poolId: string

  constructor(url: string, poolId: string, nodeId: string) {
    this.url = url
    this.poolId = poolId
    this.nodeId = nodeId
  }

  onMessage(fn: Handler): () => void {
    this.handlers.add(fn)
    return () => this.handlers.delete(fn)
  }

  connect(): Promise<void> {
    return new Promise((resolve, reject) => {
      let settled = false
      try {
        this.ws = new WebSocket(this.url)
      } catch (e) {
        reject(e)
        return
      }
      this.ws.onopen = () => {
        this.send({ type: 'join', poolId: this.poolId, nodeId: this.nodeId })
        settled = true
        resolve()
      }
      this.ws.onmessage = (ev) => {
        let msg: SignalMessage
        try { msg = JSON.parse(ev.data) } catch { return }
        this.handlers.forEach(h => h(msg))
      }
      this.ws.onerror = () => { if (!settled) { settled = true; reject(new Error('Signaling connection failed')) } }
    })
  }

  send(msg: SignalMessage): void {
    if (this.ws?.readyState === WebSocket.OPEN) this.ws.send(JSON.stringify(msg))
  }

  close(): void {
    this.ws?.close()
    this.ws = null
  }
}
