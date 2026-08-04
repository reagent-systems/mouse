// The contract a monotonic clock owes, checked the same way against both engines. Values differ
// run to run, so every line is a PROPERTY, not a reading.
const out = [];
out.push('bigint type: ' + typeof process.hrtime.bigint());
out.push('bigint positive: ' + (process.hrtime.bigint() > 0n));
out.push('own property: ' + Object.keys(process.hrtime).join(','));

// Unbound, the way eslint calls it.
const unbound = process.hrtime.bigint;
out.push('unbound works: ' + (typeof unbound() === 'bigint'));

// Monotonic: never goes backwards across many reads.
let back = 0, prev = process.hrtime.bigint();
for (let i = 0; i < 20000; i++) { const t = process.hrtime.bigint(); if (t < prev) back++; prev = t; }
out.push('never backwards: ' + (back === 0));

// Sub-millisecond resolution: a tight loop must observe SOME gap under 1ms.
let sub = false, p2 = process.hrtime.bigint();
for (let i = 0; i < 20000; i++) {
  const t = process.hrtime.bigint();
  if (t > p2 && t - p2 < 1000000n) { sub = true; break; }
  p2 = t;
}
out.push('sub-millisecond: ' + sub);

// Array form: two elements, integers, nanos in range.
const a = process.hrtime();
out.push('array shape: ' + (Array.isArray(a) && a.length === 2 && Number.isInteger(a[0]) && Number.isInteger(a[1])));
out.push('nanos in range: ' + (a[1] >= 0 && a[1] < 1e9));

// The borrow: a diff must never carry a negative nanosecond field.
let neg = 0;
for (let i = 0; i < 5000; i++) { const s = process.hrtime(); const d = process.hrtime(s); if (d[1] < 0 || d[0] < 0) neg++; }
out.push('diff never negative: ' + (neg === 0));

// performance.now: monotonic, fractional, and aligned with hrtime.
const p0 = performance.now();
out.push('perf number: ' + (typeof p0 === 'number'));
let pback = 0, pp = performance.now();
for (let i = 0; i < 20000; i++) { const t = performance.now(); if (t < pp) pback++; pp = t; }
out.push('perf never backwards: ' + (pback === 0));
out.push('perf fractional: ' + (performance.now() % 1 !== 0));
out.push('perf timeOrigin wall: ' + (performance.timeOrigin > 1.7e12));

// The two clocks must agree on elapsed time: measure the same busy span both ways.
const h0 = process.hrtime.bigint(), q0 = performance.now();
let sink = 0; for (let i = 0; i < 3e6; i++) sink += i;
const hms = Number(process.hrtime.bigint() - h0) / 1e6, qms = performance.now() - q0;
out.push('clocks agree: ' + (Math.abs(hms - qms) < Math.max(2, hms * 0.25)) + ' (sink ' + (sink > 0) + ')');
console.log(out.join('\n'));
