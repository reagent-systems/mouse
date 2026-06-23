import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { RelaySocket } from './RelaySocket.ts'

/** Minimal in-memory WebSocket stand-in driven manually by tests. */
class MockWebSocket {
  static OPEN = 1
  static instances: MockWebSocket[] = []
  readyState = MockWebSocket.OPEN
  url: string
  sent: string[] = []
  onopen: (() => void) | null = null
  onmessage: ((e: { data: string }) => void) | null = null
  onerror: (() => void) | null = null
  onclose: (() => void) | null = null

  constructor(url: string) {
    this.url = url
    MockWebSocket.instances.push(this)
    queueMicrotask(() => this.onopen?.())
  }

  send(data: string) { this.sent.push(data) }
  close() { this.readyState = 3; this.onclose?.() }

  emit(obj: unknown) { this.onmessage?.({ data: JSON.stringify(obj) }) }
  lastSent(): any { return JSON.parse(this.sent[this.sent.length - 1]) }
}

const tick = () => new Promise<void>(r => setTimeout(r, 0))

beforeEach(() => {
  MockWebSocket.instances = []
  ;(globalThis as any).WebSocket = MockWebSocket
})

afterEach(() => {
  delete (globalThis as any).WebSocket
})

async function connected(): Promise<{ relay: RelaySocket; ws: MockWebSocket }> {
  const relay = new RelaySocket('wss://example.test', 'token-123')
  relay.connect()
  await tick() // onopen fires -> auth sent
  const ws = MockWebSocket.instances[0]
  ws.emit({ type: 'auth_ok' })
  expect(relay.status).toBe('connected')
  return { relay, ws }
}

describe('RelaySocket connection', () => {
  it('authenticates with the token on open', async () => {
    const { ws } = await connected()
    const auth = JSON.parse(ws.sent[0])
    expect(auth).toEqual({ type: 'auth', token: 'token-123' })
  })

  it('moves to error and closes on auth_fail', async () => {
    const relay = new RelaySocket('wss://example.test', 'bad')
    relay.connect()
    await tick()
    MockWebSocket.instances[0].emit({ type: 'auth_fail', reason: 'invalid token' })
    expect(relay.status).toBe('error')
  })
})

describe('RelaySocket.exec', () => {
  it('sends an exec frame and resolves with the matching exec_result', async () => {
    const { relay, ws } = await connected()
    const p = relay.exec('git status')
    const frame = ws.lastSent()
    expect(frame.type).toBe('exec')
    expect(frame.command).toBe('git status')

    ws.emit({ type: 'exec_result', id: frame.id, stdout: 'clean', stderr: '', code: 0 })
    await expect(p).resolves.toEqual({ stdout: 'clean', stderr: '', code: 0 })
  })

  it('correlates concurrent exec calls by id', async () => {
    const { relay, ws } = await connected()
    const a = relay.exec('cmd-a')
    const idA = ws.lastSent().id
    const b = relay.exec('cmd-b')
    const idB = ws.lastSent().id
    expect(idA).not.toBe(idB)

    ws.emit({ type: 'exec_result', id: idB, stdout: 'B', stderr: '', code: 0 })
    ws.emit({ type: 'exec_result', id: idA, stdout: 'A', stderr: '', code: 0 })
    expect((await a).stdout).toBe('A')
    expect((await b).stdout).toBe('B')
  })

  it('rejects when not connected', async () => {
    const relay = new RelaySocket('wss://example.test', 't')
    await expect(relay.exec('noop')).rejects.toThrow('Not connected')
  })

  it('resolves in-flight execs with an error frame when the socket drops', async () => {
    const { relay, ws } = await connected()
    const p = relay.exec('long-running')
    ws.close()
    const res = await p
    expect(res.code).toBe(1)
    expect(res.stderr).toMatch(/Connection lost/)
  })
})
