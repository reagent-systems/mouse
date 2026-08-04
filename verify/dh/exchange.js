const crypto = require('crypto');
// Half the exchange: print our public key, read the peer's, print the shared secret. Run in both
// engines so each is the other's peer — a secret that agrees cannot be a private convention.
const type = process.argv[2] === 'ec' ? 'ec' : 'x25519';
const options = type === 'ec' ? { namedCurve: 'prime256v1' } : undefined;
const seedPem = process.argv[3];
const mine = crypto.generateKeyPairSync(type, options);
const fs = require('fs');
fs.writeFileSync(process.argv[4], mine.publicKey.export({ type: 'spki', format: 'pem' }));
if (seedPem && fs.existsSync(seedPem)) {
  const peer = crypto.createPublicKey(fs.readFileSync(seedPem, 'utf8'));
  const secret = crypto.diffieHellman({ privateKey: mine.privateKey, publicKey: peer });
  console.log('secret:' + secret.toString('hex'));
} else {
  console.log('published');
}
fs.writeFileSync(process.argv[4] + '.priv', mine.privateKey.export({ type: 'pkcs8', format: 'pem' }));
