#!/usr/bin/env node
/**
 * Mouse Compute Coordinator (beta)
 *
 * A tiny WebSocket signaling/membership broker for the decentralized sharded
 * WebGPU compute pool. It ONLY brokers pool membership and relays WebRTC
 * handshake messages (SDP/ICE) between peers. Shard payloads travel
 * peer-to-peer over WebRTC data channels and never pass through here.
 *
 * Protocol (JSON frames):
 *   C→S { type:"join", poolId, nodeId }
 *   S→C { type:"peers", peers:[nodeId,...] }            // sent to the newcomer
 *   S→C { type:"peer_joined", nodeId }                  // broadcast to the pool
 *   S→C { type:"peer_left", nodeId }                    // broadcast to the pool
 *   C→S { type:"signal", from, to, data }  ⇄  relayed to `to`
 *
 * Run:  node coordinator.mjs    (PORT env, default 8787)
 */
import { WebSocketServer } from 'ws'

const PORT = parseInt(process.env.PORT ?? '8787', 10)

/** poolId -> Map<nodeId, ws> */
const pools = new Map()

const wss = new WebSocketServer({ port: PORT })
const send = (ws, obj) => { try { ws.send(JSON.stringify(obj)) } catch { /* closed */ } }

wss.on('connection', (ws) => {
  let poolId = null
  let nodeId = null

  ws.on('message', (raw) => {
    let msg
    try { msg = JSON.parse(raw.toString()) } catch { return }

    if (msg.type === 'join') {
      poolId = String(msg.poolId || 'default')
      nodeId = String(msg.nodeId || Math.random().toString(36).slice(2))
      if (!pools.has(poolId)) pools.set(poolId, new Map())
      const members = pools.get(poolId)

      // Tell the newcomer who is already here, then announce them to the pool.
      send(ws, { type: 'peers', peers: [...members.keys()] })
      for (const [, peerWs] of members) send(peerWs, { type: 'peer_joined', nodeId })
      members.set(nodeId, ws)
      console.log(`[coordinator] ${nodeId} joined ${poolId} (${members.size} total)`)
      return
    }

    if (msg.type === 'signal' && poolId) {
      const target = pools.get(poolId)?.get(msg.to)
      if (target) send(target, { type: 'signal', from: nodeId, to: msg.to, data: msg.data })
    }
  })

  ws.on('close', () => {
    if (!poolId || !nodeId) return
    const members = pools.get(poolId)
    if (!members) return
    members.delete(nodeId)
    for (const [, peerWs] of members) send(peerWs, { type: 'peer_left', nodeId })
    if (members.size === 0) pools.delete(poolId)
    console.log(`[coordinator] ${nodeId} left ${poolId}`)
  })
})

console.log(`[coordinator] listening on ws://0.0.0.0:${PORT}`)
