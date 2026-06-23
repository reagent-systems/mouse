// WebGPU compute primitives. Uses `any` for GPU handles to avoid a hard
// dependency on @webgpu/types; the public API is plainly typed.
import type { MatmulDims } from './types.ts'

export interface GpuInfo {
  available: boolean
  vendor?: string
  architecture?: string
  description?: string
}

function gpu(): any {
  return (navigator as unknown as { gpu?: any }).gpu
}

export function isWebGPUAvailable(): boolean {
  return Boolean(gpu())
}

export async function getGpuInfo(): Promise<GpuInfo> {
  const g = gpu()
  if (!g) return { available: false }
  try {
    const adapter = await g.requestAdapter()
    if (!adapter) return { available: false }
    const info = adapter.info ?? (adapter.requestAdapterInfo ? await adapter.requestAdapterInfo() : undefined)
    return {
      available: true,
      vendor: info?.vendor || undefined,
      architecture: info?.architecture || undefined,
      description: info?.description || info?.device || undefined,
    }
  } catch {
    return { available: false }
  }
}

let devicePromise: Promise<any> | null = null

async function getDevice(): Promise<any> {
  if (!devicePromise) {
    devicePromise = (async () => {
      const g = gpu()
      if (!g) throw new Error('WebGPU is not available in this environment')
      const adapter = await g.requestAdapter()
      if (!adapter) throw new Error('No suitable GPU adapter found')
      return adapter.requestDevice()
    })()
  }
  return devicePromise
}

const WGSL = /* wgsl */ `
struct Dims { m: u32, k: u32, n: u32, _pad: u32 };
@group(0) @binding(0) var<storage, read> a : array<f32>;
@group(0) @binding(1) var<storage, read> b : array<f32>;
@group(0) @binding(2) var<storage, read_write> c : array<f32>;
@group(0) @binding(3) var<uniform> dims : Dims;

@compute @workgroup_size(8, 8, 1)
fn main(@builtin(global_invocation_id) gid : vec3<u32>) {
  let row = gid.x;
  let col = gid.y;
  if (row >= dims.m || col >= dims.n) { return; }
  var acc : f32 = 0.0;
  for (var i : u32 = 0u; i < dims.k; i = i + 1u) {
    acc = acc + a[row * dims.k + i] * b[i * dims.n + col];
  }
  c[row * dims.n + col] = acc;
}
`

let pipelinePromise: Promise<any> | null = null

async function getPipeline(): Promise<{ device: any; pipeline: any }> {
  const device = await getDevice()
  if (!pipelinePromise) {
    pipelinePromise = (async () => {
      const module = device.createShaderModule({ code: WGSL })
      return device.createComputePipelineAsync({ layout: 'auto', compute: { module, entryPoint: 'main' } })
    })()
  }
  return { device, pipeline: await pipelinePromise }
}

/**
 * Compute C = A·B on the GPU. A is m×k, B is k×n, result is m×n (row-major).
 */
export async function runMatmul(a: Float32Array, b: Float32Array, dims: MatmulDims): Promise<Float32Array> {
  const { m, k, n } = dims
  if (a.length !== m * k) throw new Error(`A has ${a.length} elements, expected ${m * k}`)
  if (b.length !== k * n) throw new Error(`B has ${b.length} elements, expected ${k * n}`)

  const { device, pipeline } = await getPipeline()

  const aBuf = device.createBuffer({ size: a.byteLength, usage: 0x80 | 0x8 }) // STORAGE | COPY_DST
  const bBuf = device.createBuffer({ size: b.byteLength, usage: 0x80 | 0x8 })
  const cBytes = m * n * 4
  const cBuf = device.createBuffer({ size: cBytes, usage: 0x80 | 0x4 }) // STORAGE | COPY_SRC
  const dimsBuf = device.createBuffer({ size: 16, usage: 0x40 | 0x8 }) // UNIFORM | COPY_DST
  const readBuf = device.createBuffer({ size: cBytes, usage: 0x1 | 0x2 }) // MAP_READ | COPY_DST

  device.queue.writeBuffer(aBuf, 0, a)
  device.queue.writeBuffer(bBuf, 0, b)
  device.queue.writeBuffer(dimsBuf, 0, new Uint32Array([m, k, n, 0]))

  const bindGroup = device.createBindGroup({
    layout: pipeline.getBindGroupLayout(0),
    entries: [
      { binding: 0, resource: { buffer: aBuf } },
      { binding: 1, resource: { buffer: bBuf } },
      { binding: 2, resource: { buffer: cBuf } },
      { binding: 3, resource: { buffer: dimsBuf } },
    ],
  })

  const encoder = device.createCommandEncoder()
  const pass = encoder.beginComputePass()
  pass.setPipeline(pipeline)
  pass.setBindGroup(0, bindGroup)
  pass.dispatchWorkgroups(Math.ceil(m / 8), Math.ceil(n / 8), 1)
  pass.end()
  encoder.copyBufferToBuffer(cBuf, 0, readBuf, 0, cBytes)
  device.queue.submit([encoder.finish()])

  await readBuf.mapAsync(0x1) // MAP_READ
  const out = new Float32Array(readBuf.getMappedRange().slice(0))
  readBuf.unmap()

  aBuf.destroy?.()
  bBuf.destroy?.()
  cBuf.destroy?.()
  dimsBuf.destroy?.()
  readBuf.destroy?.()

  return out
}

/** Quick self-benchmark; returns approximate GFLOP/s for an n×n square matmul. */
export async function benchmark(size = 256): Promise<{ ms: number; gflops: number }> {
  const a = randomMatrix(size * size)
  const b = randomMatrix(size * size)
  const t0 = performance.now()
  await runMatmul(a, b, { m: size, k: size, n: size })
  const ms = performance.now() - t0
  const flops = 2 * size * size * size
  return { ms, gflops: flops / (ms / 1000) / 1e9 }
}

export function randomMatrix(len: number): Float32Array {
  const out = new Float32Array(len)
  for (let i = 0; i < len; i++) out[i] = Math.random()
  return out
}
