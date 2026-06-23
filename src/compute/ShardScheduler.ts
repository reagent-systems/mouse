import type { MatmulDims, ShardResult, ShardTask, Worker } from './types.ts'

export interface ShardPlan {
  rowStart: number
  rows: number
}

/**
 * Split `m` rows into shards of at most `shardRows` rows each.
 * Pure + deterministic so it is easy to reason about and test.
 */
export function planShards(m: number, shardRows: number): ShardPlan[] {
  if (shardRows <= 0) throw new Error('shardRows must be > 0')
  const plans: ShardPlan[] = []
  for (let rowStart = 0; rowStart < m; rowStart += shardRows) {
    plans.push({ rowStart, rows: Math.min(shardRows, m - rowStart) })
  }
  return plans
}

/** Build the concrete shard tasks for a job from A, B and a shard plan. */
export function buildTasks(
  jobId: string,
  a: Float32Array,
  b: Float32Array,
  dims: MatmulDims,
  plans: ShardPlan[],
): ShardTask[] {
  const { k } = dims
  return plans.map((plan, shardId) => ({
    jobId,
    shardId,
    rowStart: plan.rowStart,
    rows: plan.rows,
    dims,
    a: a.subarray(plan.rowStart * k, (plan.rowStart + plan.rows) * k),
    b, // B is shared by every shard
  }))
}

/** Stitch shard results back into a single m×n matrix. */
export function mergeResults(dims: MatmulDims, results: ShardResult[]): Float32Array {
  const out = new Float32Array(dims.m * dims.n)
  for (const r of results) {
    out.set(r.c, r.rowStart * dims.n)
  }
  return out
}

export interface JobReport {
  c: Float32Array
  totalMs: number
  perShard: ShardResult[]
}

/**
 * Distribute shard tasks across the given workers and gather results.
 *
 * Uses a simple weighted work-stealing queue: each worker pulls the next
 * pending shard as soon as it is free, so faster GPUs naturally do more work.
 */
export async function runJob(
  dims: MatmulDims,
  tasks: ShardTask[],
  workers: Worker[],
  onResult?: (r: ShardResult) => void,
): Promise<JobReport> {
  if (workers.length === 0) throw new Error('No workers available')
  const queue = [...tasks]
  const results: ShardResult[] = []
  const t0 = performance.now()

  async function pump(worker: Worker): Promise<void> {
    for (;;) {
      const task = queue.shift()
      if (!task) return
      const result = await worker.run(task)
      results.push(result)
      onResult?.(result)
    }
  }

  await Promise.all(workers.map(pump))
  results.sort((a, b) => a.shardId - b.shardId)

  return { c: mergeResults(dims, results), totalMs: performance.now() - t0, perShard: results }
}
