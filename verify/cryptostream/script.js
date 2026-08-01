const crypto = require('crypto'), { Readable } = require('stream');
const out = [];
const data = Buffer.from('stream me through a hash');
const expected = crypto.createHash('sha256').update(data).digest('hex');
out.push('classic: ' + expected);

const hash = crypto.createHash('sha256');
out.push('is a stream: ' + (typeof hash.pipe === 'function') + ' ' + (typeof hash.write === 'function'));

// Pipe a readable INTO the hash, then read the digest out of it.
Readable.from([data.slice(0, 7), data.slice(7)]).pipe(hash);
hash.on('finish', () => {
  const digest = hash.read();
  out.push('piped digest matches: ' + (Buffer.isBuffer(digest) && digest.toString('hex') === expected));

  // setEncoding makes read() give a string, which is how most code uses it.
  const hex = crypto.createHash('sha256');
  hex.setEncoding('hex');
  hex.end(data);
  out.push('setEncoding hex: ' + (hex.read() === expected));

  // Hmac the same way.
  const key = 'k';
  const hmacExpected = crypto.createHmac('sha256', key).update(data).digest('hex');
  const hmac = crypto.createHmac('sha256', key);
  hmac.setEncoding('hex');
  hmac.end(data);
  out.push('hmac stream: ' + (hmac.read() === hmacExpected));

  // A cipher is a Transform too: piping through gives the ciphertext.
  const k = Buffer.alloc(32, 7), iv = Buffer.alloc(16, 9);
  const single = crypto.createCipheriv('aes-256-cbc', k, iv);
  const oneShot = Buffer.concat([single.update(data), single.final()]);
  const cipher = crypto.createCipheriv('aes-256-cbc', k, iv);
  const chunks = [];
  cipher.on('data', c => chunks.push(c));
  cipher.on('end', () => {
    out.push('cipher stream matches one-shot: ' + Buffer.concat(chunks).equals(oneShot));
    // update() after digest() is an error in node, and that matters: it is how a program
    // learns it reused a finished hash.
    const spent = crypto.createHash('sha256');
    spent.digest();
    try { spent.update('more'); out.push('update after digest: ALLOWED'); }
    catch (error) { out.push('update after digest: ' + error.code); }
    console.log(out.join('\n'));
  });
  cipher.end(data);
});
