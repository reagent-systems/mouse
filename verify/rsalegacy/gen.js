const crypto = require('crypto'), fs = require('fs');
const pair = crypto.generateKeyPairSync('rsa', { modulusLength: 2048 });
fs.writeFileSync('k.priv', pair.privateKey.export({ type: 'pkcs8', format: 'pem' }));
fs.writeFileSync('k.pub', pair.publicKey.export({ type: 'spki', format: 'pem' }));
console.log('generated');
