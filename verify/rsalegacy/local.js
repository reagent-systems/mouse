const crypto = require('crypto'), fs = require('fs');
const priv = fs.readFileSync('k.priv', 'utf8'), pub = fs.readFileSync('k.pub', 'utf8');
const message = Buffer.from('the private key seals it');
const sealed = crypto.privateEncrypt(priv, message);
console.log('round trip: ' + crypto.publicDecrypt(pub, sealed).toString());
console.log('block is modulus-sized: ' + (sealed.length === 256));
// The normal direction still works alongside it.
const enc = crypto.publicEncrypt(pub, message);
console.log('public/private direction: ' + crypto.privateDecrypt(priv, enc).toString());
try { crypto.publicDecrypt(pub, Buffer.alloc(256)); console.log('garbage: ALLOWED'); }
catch (e) { console.log('garbage refused: ' + (e.code || e.name)); }
