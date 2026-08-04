const crypto = require('crypto');
const h = crypto.createHash('sha256');
h.setEncoding('hex');
h.end(Buffer.from('abc'));
console.log('after end, read() =', JSON.stringify(h.read()));
h.on('readable', () => console.log('readable fired, read() =', JSON.stringify(h.read())));
h.on('end', () => console.log('end fired'));
h.on('data', d => console.log('data event =', JSON.stringify(String(d))));
setTimeout(() => console.log('done'), 60);
