const crypto = require('crypto'), fs = require('fs');
console.log(crypto.publicDecrypt(fs.readFileSync('k.pub', 'utf8'), fs.readFileSync(process.argv[2])).toString('utf8'));
