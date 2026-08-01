const crypto = require('crypto');
// RFC 7914 §12 publishes these three, so a match is against the standard and not just node.
const rfc = [
  ['', '', 16, 1, 1, 64],
  ['password', 'NaCl', 1024, 8, 16, 64],
  ['pleaseletmein', 'SodiumChloride', 16384, 8, 1, 64],
];
for (const [pw, salt, N, r, p, len] of rfc) {
  console.log(`N=${N} r=${r} p=${p}: ` + crypto.scryptSync(pw, salt, len, { N, r, p }).toString('hex'));
}
// Defaults, the option aliases, a Buffer password, and a non-multiple-of-64 key length.
console.log('defaults:', crypto.scryptSync('pass', 'salt', 32).toString('hex'));
console.log('aliases :', crypto.scryptSync('a', 'b', 21, { cost: 16, blockSize: 1, parallelization: 2 }).toString('hex'));
console.log('buffers :', crypto.scryptSync(Buffer.from('pw'), Buffer.from('sl'), 16, { N: 16, r: 1, p: 1 }).toString('hex'));

// Rejected parameters must carry node's code.
const bad = [[{ N: 3 }, 'N not a power of two'], [{ N: 1024, r: 8, p: 1, maxmem: 1024 }, 'over maxmem'], [{ N: 1 }, 'N too small']];
for (const [options, label] of bad) {
  try { crypto.scryptSync('a', 'b', 8, options); console.log(label + ': ALLOWED'); }
  catch (error) { console.log(label + ': ' + error.code); }
}
// The async form reports through a callback, and after the synchronous return.
const order = [];
crypto.scrypt('pw', 'salt', 16, { N: 16, r: 1, p: 1 }, (error, key) => {
  order.push('callback:' + (error ? error.code : key.toString('hex')));
  // Bad params THROW here rather than reaching the callback, which is node's shape.
  try { crypto.scrypt('pw', 'salt', 8, { N: 3 }, () => order.push('bad-async:called back')); }
  catch (error) { order.push('bad-async threw:' + error.code); }
  console.log(order.join(' | '));
});
order.push('sync-first');
