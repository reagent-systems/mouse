// Shared types for the decentralized sharded compute pool (beta).
//
// The pool distributes a large linear-algebra job (matrix multiply — the core
// primitive behind a transformer layer) across many browser GPUs via WebGPU.
// A job is split into row-block "shards"; each worker computes one shard and
// returns its slice of the output, which the requester reassembles.

export type PoolRole = 'idle' | 'worker' | 'requester'

export type PoolConnection = 'disabled' | 'solo' | 'connecting' | 'connected' | 'error'

export interface MatmulDims {
  m: number // rows of A / C
  k: number // shared dimension
  n: number // cols of B / C
}

/** A unit of work: rows [rowStart, rowStart+rows) of A multiplied by the full B. */
export interface ShardTask {
  jobId: string
  shardId: number
  rowStart: number
  rows: number
  dims: MatmulDims
  a: Float32Array // length rows*k
  b: Float32Array // length k*n (shared across shards of a job)
}

export interface ShardResult {
  jobId: string
  shardId: number
  rowStart: number
  rows: number
  /** length rows*n */
  c: Float32Array
  /** id of the node that computed it ("self" or a peer id) */
  computedBy: string
  ms: number
}

/** Where a shard can be executed. */
export interface Worker {
  id: string
  /** Compute a shard and resolve with its result slice. */
  run(task: ShardTask): Promise<ShardResult>
  /** Rough relative capacity used for load balancing (higher = faster). */
  weight: number
}

// ── Signaling protocol (client ⇄ coordinator) ─────────────────────────────
// The coordinator only brokers WebRTC connections + pool membership; it never
// sees shard data, which flows peer-to-peer over data channels.

export type SignalMessage =
  | { type: 'join'; poolId: string; nodeId: string }
  | { type: 'peers'; peers: string[] }
  | { type: 'peer_joined'; nodeId: string }
  | { type: 'peer_left'; nodeId: string }
  | { type: 'signal'; from: string; to: string; data: unknown }

// ── Peer wire protocol (over RTCDataChannel) ──────────────────────────────

export type PeerMessage =
  | { kind: 'task'; jobId: string; shardId: number; rowStart: number; rows: number; dims: MatmulDims }
  | { kind: 'result'; jobId: string; shardId: number; rowStart: number; rows: number; ms: number }
