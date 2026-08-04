const crypto = require('crypto'), fs = require('fs');
const type = process.argv[2], tag = process.argv[3];
const options = type === 'ec' ? { namedCurve: 'prime256v1' } : undefined;
const pair = crypto.generateKeyPairSync(type, options);
fs.writeFileSync(tag + '.pub', pair.publicKey.export({ type: 'spki', format: 'pem' }));
fs.writeFileSync(tag + '.key', pair.privateKey.export({ type: 'pkcs8', format: 'pem' }));
console.log('generated ' + tag);
