const crypto = require('crypto'), fs = require('fs');
// My private key, the peer's public key, one shared secret.
const priv = crypto.createPrivateKey(fs.readFileSync(process.argv[2], 'utf8'));
const pub = crypto.createPublicKey(fs.readFileSync(process.argv[3], 'utf8'));
console.log(crypto.diffieHellman({ privateKey: priv, publicKey: pub }).toString('hex'));
