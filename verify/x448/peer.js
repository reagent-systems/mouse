const c = require('crypto');
const pair = c.generateKeyPairSync('x448', {
  publicKeyEncoding: { type: 'spki', format: 'pem' },
  privateKeyEncoding: { type: 'pkcs8', format: 'pem' },
});
const theirs = c.createPublicKey(JSON.parse(process.argv[2]));
const secret = c.diffieHellman({ privateKey: c.createPrivateKey(pair.privateKey), publicKey: theirs });
console.log(JSON.stringify(pair.publicKey));
console.log(secret.toString('hex'));