const c = require('crypto');
const d = c.getDiffieHellman('modp14');
d.generateKeys();
console.log(d.getPublicKey().toString('hex'));
console.log(d.computeSecret(Buffer.from(process.argv[2], 'hex')).toString('hex'));