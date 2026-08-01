const zlib = require('zlib'), fs = require('fs');
console.log(zlib.brotliDecompressSync(fs.readFileSync(process.argv[2])).toString('utf8'));
