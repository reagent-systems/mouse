const crypto = require('crypto'), fs = require('fs');
fs.writeFileSync(process.argv[3], crypto.privateEncrypt(fs.readFileSync('k.priv', 'utf8'),
                                                        Buffer.from(process.argv[2], 'utf8')));
console.log('sealed');
