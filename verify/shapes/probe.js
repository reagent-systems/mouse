// The export sweep called functions. This one looks at OBJECTS: for each instance, list every
// property reachable on it and up its prototype chain, and diff against node. Two of this
// engine's worst bugs were exactly this shape — Buffer's statics were non-enumerable (express
// broke on every route) and fs.Stats had no `mode` (chokidar hid every file) — and neither was
// visible from the export list.
const fs = require('fs');
const cases = {
  'Buffer.statics': () => Buffer,
  'Buffer.instance': () => Buffer.alloc(4),
  'fs.Stats': () => fs.statSync(process.argv[1]),
  'fs.Dirent': () => fs.readdirSync('.', { withFileTypes: true })[0],
  'stream.Readable': () => new (require('stream').Readable)({ read() {} }),
  'stream.Writable': () => new (require('stream').Writable)({ write(c, e, cb) { cb(); } }),
  'stream.Transform': () => new (require('stream').Transform)({ transform(c, e, cb) { cb(); } }),
  'events.EventEmitter': () => new (require('events'))(),
  'net.Socket': () => new (require('net').Socket)(),
  'net.Server': () => require('net').createServer(),
  'http.Server': () => require('http').createServer(),
  'http.Agent': () => new (require('http').Agent)(),
  'crypto.Hash': () => require('crypto').createHash('sha256'),
  'crypto.Hmac': () => require('crypto').createHmac('sha256', 'k'),
  'crypto.Cipher': () => require('crypto').createCipheriv('aes-256-gcm', Buffer.alloc(32), Buffer.alloc(12)),
  'zlib.Gzip': () => require('zlib').createGzip(),
  'url.URL': () => new URL('https://a.example/b?c=d#e'),
  'url.URLSearchParams': () => new URLSearchParams('a=1&b=2'),
  'string_decoder': () => new (require('string_decoder').StringDecoder)('utf8'),
  'TextEncoder': () => new TextEncoder(),
  'TextDecoder': () => new TextDecoder(),
  'Headers': () => new Headers({ a: 'b' }),
  'Response': () => new Response('x'),
  'Request': () => new Request('https://a.example/'),
  'AbortController': () => new AbortController(),
  'worker.MessagePort': () => new (require('worker_threads').MessageChannel)().port1,
  'process': () => process,
  'process.stdout': () => process.stdout,
};
const rows = [];
for (const label of Object.keys(cases).sort()) {
  let value;
  try { value = cases[label](); } catch (error) { rows.push(label + '\t<construct failed>'); continue; }
  const names = new Set();
  // The WHOLE prototype chain, not a fixed number of links. A depth cap of 6 made this
  // investigation lie: node's crypto.Hash chain is seven deep (it has an extra LazyTransform
  // layer) and node's Readable.prototype defines on/off/addListener/removeListener as OWN
  // properties, while ours inherits them from EventEmitter one level further down. The cap
  // therefore cut our chain BEFORE EventEmitter and reported `off` and friends as missing from
  // methods we plainly have. What matters is whether a property is REACHABLE, not which link
  // of the chain holds it.
  let target = value;
  let depth = 0;
  while (target && target !== Object.prototype && depth < 32) {
    for (const key of Object.getOwnPropertyNames(target)) names.add(key);
    target = Object.getPrototypeOf(target);
    depth += 1;
  }
  // Internals are noise: node's are prefixed or Symbol-keyed, and ours differ by construction.
  const useful = Array.from(names).filter(n => !n.startsWith('_') && n !== 'constructor').sort();
  rows.push(label + '\t' + useful.join(' '));
}
console.log(rows.join('\n'));
// stdin and other handles must not keep this alive.
process.exit(0);
