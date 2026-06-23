# Compute Pool (beta)

> **Status: experimental beta.** A research scaffold for a *decentralized,
> sharded WebGPU compute pool* — many browser GPUs cooperating to run model
> inference workloads, contributed voluntarily to form a free, shared pool.

This module is **off by default** and isolated from the rest of the app behind a
feature flag. Enabling it adds a ⚡ launcher that opens a control panel.

## Idea

Large-model inference is dominated by big matrix multiplies (the core op in a
transformer layer). Instead of one device doing all of it, the pool **splits each
matmul into row-block shards** and spreads them across every participating GPU,
then reassembles the result. Every participant is simultaneously:

- a **worker** — computing shards for others on its GPU, and
- a **requester** — able to dispatch its own jobs to the pool.

The more peers join a pool, the more aggregate compute is available to each job.

## Architecture

```
                ┌──────────────────────── coordinator (signaling only) ───────┐
                │  membership + WebRTC handshake relay; never sees shard data  │
                └───────▲───────────────────────────────▲────────────────────-┘
                        │ join / SDP / ICE              │
   ┌────────────────────┴─────────┐        ┌────────────┴─────────────────────┐
   │ Node A                        │  P2P   │ Node B                            │
   │  ComputePool                  │◀──────▶│  ComputePool                      │
   │   ├─ webgpu.ts  (matmul)      │ shards │   ├─ webgpu.ts  (matmul)          │
   │   ├─ ShardScheduler (split)   │  over  │   ├─ ShardScheduler              │
   │   └─ PeerLink (RTCDataChannel)│ WebRTC │   └─ PeerLink                     │
   └──────────────────────────────┘        └───────────────────────────────────┘
```

### Files

| File | Responsibility |
| ---- | -------------- |
| `webgpu.ts` | WebGPU device + a real WGSL matmul kernel; capability probe; benchmark |
| `ShardScheduler.ts` | Pure split / build / merge + weighted work-stealing distribution |
| `signaling.ts` | WebSocket client to the coordinator (join + relay SDP/ICE) |
| `peer.ts` | `PeerLink` — a peer as a remote `Worker` over an `RTCDataChannel` |
| `ComputePool.ts` | Orchestrates GPU probe, peers, and `runSharded()` jobs |
| `ComputePoolView.ts` | Beta control panel (status + demo run + per-shard log) |
| `types.ts` | Shared task/result/signaling/peer protocol types |

Shard data is exchanged **peer-to-peer**; the coordinator only brokers
membership and the WebRTC handshake.

## Running it

1. Enable the flag in `.env`:

   ```env
   VITE_ENABLE_COMPUTE_POOL=true
   # optional — for a multi-node pool:
   VITE_COMPUTE_COORDINATOR_URL=ws://localhost:8787
   VITE_COMPUTE_POOL_ID=mouse-public-beta
   ```

2. (Optional, for multiple nodes) start the reference coordinator:

   ```bash
   cd compute-coordinator && npm install && npm start
   ```

3. Run the app, open the ⚡ panel, and press **Run sharded job**. With no
   coordinator the pool runs as a single node ("solo") and still demonstrates the
   full shard → compute → merge pipeline on one GPU.

## Limitations / TODO (beta)

- The job primitive is a dense `f32` matmul; wiring a real model's layers/weights
  on top is future work.
- The matmul kernel is a straightforward (non-tiled) implementation — fine for
  the pipeline demo, not yet tuned for peak throughput.
- No verification/reputation of peer results, no encryption-at-rest of weights,
  and no anti-abuse for a truly public pool — all required before any real
  "free inference for everyone" deployment.
- Peer transport is wired but only exercised when a coordinator + ≥2 nodes are
  present; the solo path is the tested one.
