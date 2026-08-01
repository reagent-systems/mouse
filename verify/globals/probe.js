// Third sweep: the GLOBALS. Module exports and instance shapes have been swept; nothing has
// looked at globalThis, where the web-standard surface modern packages reach for directly
// (structuredClone, performance, AbortSignal.timeout, atob, queueMicrotask) lives.
const names = new Set();
for (const key of Object.getOwnPropertyNames(globalThis)) names.add(key);
// V8/JSC intrinsics and our own scaffolding are noise; only what a program would use matters.
const skip = /^(__|_|\$)|^(Array|Object|Function|String|Number|Boolean|Symbol|Math|JSON|Date|RegExp|Error|TypeError|RangeError|SyntaxError|EvalError|ReferenceError|URIError|Map|Set|WeakMap|WeakSet|Promise|Proxy|Reflect|BigInt|Int8Array|Uint8Array|Uint8ClampedArray|Int16Array|Uint16Array|Int32Array|Uint32Array|Float32Array|Float64Array|BigInt64Array|BigUint64Array|ArrayBuffer|SharedArrayBuffer|DataView|Atomics|escape|unescape|eval|isNaN|isFinite|parseInt|parseFloat|decodeURI|decodeURIComponent|encodeURI|encodeURIComponent|undefined|NaN|Infinity|globalThis|WebAssembly|Intl|AggregateError|FinalizationRegistry|WeakRef|Iterator|AsyncFunction|GeneratorFunction)$/;
const rows = [];
for (const name of Array.from(names).sort()) {
  if (skip.test(name)) continue;
  let kind;
  try {
    const value = globalThis[name];
    kind = value === null ? 'null' : typeof value;
    if (kind === 'function') kind += /^[A-Z]/.test(name) ? ':class' : ':fn';
  } catch (error) { kind = 'threw'; }
  rows.push(name + '\t' + kind);
}
console.log(rows.join('\n'));
