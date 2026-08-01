const zlib = require('zlib'), fs = require('fs');
fs.writeFileSync(process.argv[3], zlib.brotliCompressSync(Buffer.from(process.argv[2], 'utf8')));
console.log('packed');
