// Every API the docs still claim is ABSENT, tested against the engine. Four times this session
// the RECORD was wrong rather than the code, and a gap list rots silently — nothing fails when it
// goes stale. This is the gate for that.
//
// Each entry: the claim as the docs state it, and a probe. "works" means the doc is STALE.
const probes = [
  ['crypto.subtle',              () => require('crypto').subtle !== undefined],
  ['crypto.createDiffieHellman', () => { require('crypto').createDiffieHellman(512); return true; }],
  ['crypto.generatePrime',       () => { require('crypto').generatePrimeSync(32); return true; }],
  ['crypto.checkPrime',          () => { require('crypto').checkPrimeSync(7n); return true; }],
  ['crypto.getDiffieHellman',    () => { require('crypto').getDiffieHellman('modp1'); return true; }],
  ['path.matchesGlob',           () => { require('path').matchesGlob('a', '*'); return true; }],
  ['dns.resolveTlsa',            () => new Promise(r => require('dns').resolveTlsa('_25._tcp.mail.ietf.org', (e, rec) => r(!e && Array.isArray(rec) && rec.length > 0 && typeof rec[0].certUsage === 'number')))],
  ['worker.moveMessagePortToContext', () => { const wt = require('worker_threads'), vm = require('vm');
                                         const ctx = vm.createContext({});
                                         const { port2 } = new wt.MessageChannel();
                                         return typeof wt.moveMessagePortToContext(port2, ctx).postMessage === 'function'; }],
  ['zlib.zstdCompressSync',      () => { require('zlib').zstdCompressSync(Buffer.from('x')); return true; }],
  ['https.createServer',         () => { require('https').createServer(); return true; }],
  ['crypto keyType dsa',         () => { require('crypto').generateKeyPairSync('dsa', { modulusLength: 1024 }); return true; }],
  ['crypto keyType x448',        () => { const c = require('crypto');
                                         const a = c.generateKeyPairSync('x448'), b = c.generateKeyPairSync('x448');
                                         return c.diffieHellman({ privateKey: a.privateKey, publicKey: b.publicKey })
                                           .equals(c.diffieHellman({ privateKey: b.privateKey, publicKey: a.publicKey })); }],
  ['SharedArrayBuffer across workers', () => typeof require('worker_threads').getEnvironmentData === 'function' && typeof SharedArrayBuffer !== 'undefined' && (() => { try { new (require('worker_threads').Worker)('', { eval: true, workerData: new SharedArrayBuffer(8) }); return true; } catch (e) { return false; } })()],
  ['fs.glob',                    () => { require('fs').globSync('*'); return true; }],
  ['crypto.privateEncrypt',      () => { const c = require('crypto'); const k = c.generateKeyPairSync('rsa', { modulusLength: 2048 }); c.privateEncrypt(k.privateKey, Buffer.from('x')); return true; }],
  ['crypto.scrypt',              () => { require('crypto').scryptSync('a', 'b', 8, { N: 16, r: 1, p: 1 }); return true; }],
  ['zlib.brotliCompressSync',    () => { require('zlib').brotliCompressSync(Buffer.from('x')); return true; }],
  ['process.hrtime.bigint',      () => { const f = process.hrtime.bigint; return typeof f() === 'bigint'; }],
  ['vm.runInContext',            () => { const vm = require('vm'); const s = { a: 1 };
                                         const c = vm.createContext(s);
                                         vm.runInContext('b = a + 41', c);
                                         return s.b === 42 && vm.runInContext('typeof process', c) === 'undefined'; }],
  ['unhandledRejection hook',    () => { let fired = false;
                                         process.on('unhandledRejection', () => { fired = true; });
                                         Promise.reject(new Error('probe'));
                                         // Reported at the microtask checkpoint, so the answer
                                         // is not available until a later turn.
                                         return new Promise(r => setTimeout(() => r(fired), 10)); }],
  ['assert.AssertionError',      () => { try { require('assert').strictEqual(1, 2); } catch (e) {
                                           return e.name === 'AssertionError' && e.code === 'ERR_ASSERTION' &&
                                                  e.operator === 'strictEqual' && e.actual === 1 && e.expected === 2; } }],
  ['assert deep NaN/Map',        () => { const a = require('assert');
                                         a.deepStrictEqual({ x: NaN }, { x: NaN });
                                         a.deepStrictEqual(new Map([[1, 2]]), new Map([[1, 2]]));
                                         try { a.deepStrictEqual({ a: undefined }, {}); return false; } catch (e) { return true; } }],
  ['assert.throws matches',      () => { const a = require('assert');
                                         try { a.throws(() => { throw new TypeError('x'); }, RangeError); return false; }
                                         catch (e) { return e.operator === 'throws'; } }],
  ['url.pathToFileURL',          () => { const u = require('url').pathToFileURL('/a/b c.js');
                                         u.searchParams.append('m', '1');
                                         return u.href === 'file:///a/b%20c.js?m=1'; }],
];
(async () => {
  const out = [];
  for (const [label, probe] of probes) {
    let works;
    try { works = !!(await probe()); } catch (e) { works = false; }
    out.push(label + ': ' + (works ? 'WORKS' : 'absent'));
  }
  console.log(out.join('\n'));
  process.exit(0);
})();
