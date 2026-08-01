// A serializer is only useful if what comes back IS what went in. JSON silently loses every
// one of these — and silently is the problem: a Map becomes {} rather than an error.
const v8 = require('v8'), assert = require('assert');
const round = (value) => v8.deserialize(v8.serialize(value));
const out = [];
const check = (label, value, verify) => {
  try { out.push(label + ': ' + verify(round(value))); }
  catch (e) { out.push(label + ' THREW ' + String(e.message).slice(0, 60)); }
};
check('map', new Map([['a', 1], ['b', 2]]), m => m instanceof Map && m.get('b') === 2 && m.size === 2);
check('set', new Set([1, 'x']), s => s instanceof Set && s.has('x') && s.size === 2);
check('nested map', new Map([['k', new Map([['deep', 9]])]]), m => m.get('k').get('deep') === 9);
check('map object key', new Map([[{ id: 1 }, 'v']]), m => [...m.keys()][0].id === 1);
check('set of objects', new Set([{ a: 1 }]), s => [...s][0].a === 1);
check('date', new Date(1700000000000), d => d instanceof Date && d.getTime() === 1700000000000);
check('regexp', /ab+c/gi, r => r instanceof RegExp && r.source === 'ab+c' && r.flags === 'gi');
check('buffer', Buffer.from([1, 2, 255]), b => Buffer.isBuffer(b) && b[2] === 255 && b.length === 3);
check('uint8array', new Uint8Array([7, 8]), a => a instanceof Uint8Array && a[1] === 8);
check('float64array', new Float64Array([1.5, 2.5]), a => a instanceof Float64Array && a[1] === 2.5);
check('undefined', undefined, v => v === undefined);
check('undefined in object', { a: undefined, b: 1 }, o => 'a' in o && o.a === undefined && o.b === 1);
check('null', null, v => v === null);
check('bigint', 123456789012345678901234567890n, v => typeof v === 'bigint' && v === 123456789012345678901234567890n);
check('NaN', NaN, v => Number.isNaN(v));
check('Infinity', Infinity, v => v === Infinity);
check('negative zero', -0, v => Object.is(v, -0));
check('nested arrays', [1, [2, [3, [4]]]], a => a[1][1][1][0] === 4);
check('sparse-ish object', { x: { y: { z: 'deep' } } }, o => o.x.y.z === 'deep');
// A cycle: jest's haste map has plenty.
const cyclic = { name: 'root' }; cyclic.self = cyclic; cyclic.list = [cyclic];
check('cycle', cyclic, o => o.self === o && o.list[0] === o && o.name === 'root');
// Shared reference identity must survive, not be duplicated.
const shared = { s: 1 };
check('shared identity', { a: shared, b: shared }, o => o.a === o.b);
// The shape jest actually stores.
const haste = new Map([['/a.js', { id: 'a', deps: new Set(['/b.js']), mtime: new Date(5) }]]);
check('haste-like', haste, m => m.get('/a.js').deps.has('/b.js') && m.get('/a.js').mtime.getTime() === 5);
check('empty containers', { m: new Map(), s: new Set(), a: [] }, o => o.m.size === 0 && o.s.size === 0 && o.a.length === 0);
check('returns Buffer', 1, () => Buffer.isBuffer(v8.serialize({ a: 1 })));
console.log(out.join('\n'));
