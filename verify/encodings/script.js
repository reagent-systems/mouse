// The ENCODING audit. A wrong encoding produces wrong BYTES or wrong TEXT silently — the same
// shape as the range read that returned the whole file. Every named encoding, across every path
// that takes one: Buffer.from/toString, fs read/write, StringDecoder, and stream setEncoding.
const fs = require('fs');
const { StringDecoder } = require('string_decoder');
const { Readable } = require('stream');
const out = [];
const say = (l, v) => out.push(l + ': ' + v);
const check = (l, fn) => { try { say(l, fn()); } catch (e) { say(l, 'THREW ' + String(e.message).slice(0, 40)); } };
const names = ['utf8', 'utf-8', 'utf16le', 'ucs2', 'ucs-2', 'latin1', 'binary', 'ascii',
               'hex', 'base64', 'base64url'];

fs.rmSync('enc', { recursive: true, force: true });
fs.mkdirSync('enc');

// Buffer.isEncoding must agree about what exists at all.
check('isEncoding', () => JSON.stringify(names.map(n => Buffer.isEncoding(n))));

// A round trip through every encoding, on text that needs more than ASCII.
for (const name of names) {
  check('roundtrip ' + name, () => {
    const source = name === 'hex' ? 'deadbeef' : (name === 'base64' || name === 'base64url') ? 'aGVsbG8' : 'héllo€';
    const bytes = Buffer.from(source, name);
    return bytes.toString('hex') + ' -> ' + JSON.stringify(bytes.toString(name));
  });
}
// base64url must use -_ and drop padding; base64 must use +/ and keep it.
check('base64 vs base64url', () => {
  const bytes = Buffer.from([251, 255, 190, 255]);
  return bytes.toString('base64') + ' | ' + bytes.toString('base64url');
});
check('base64url decodes -_', () => Buffer.from('-_-_', 'base64url').toString('hex'));
check('base64 decodes +/', () => Buffer.from('+/+/', 'base64').toString('hex'));
// utf16le pairs, where a naive byte copy goes wrong.
check('utf16le of a surrogate pair', () => Buffer.from('𝄞', 'utf16le').toString('hex'));
check('utf16le back', () => Buffer.from('34d81edd', 'hex').toString('utf16le'));
// latin1 keeps every byte; ascii masks the high bit.
check('latin1 high bytes', () => Buffer.from([0xff, 0x80]).toString('latin1').split('').map(c => c.charCodeAt(0)).join(','));
check('ascii high bytes', () => Buffer.from([0xff, 0x80]).toString('ascii').split('').map(c => c.charCodeAt(0)).join(','));
// toString with a range, which the range audit did not cover for encodings.
check('toString hex range', () => Buffer.from([1, 2, 3, 4]).toString('hex', 1, 3));

// fs must honour an encoding on the way in AND out.
for (const name of ['utf8', 'latin1', 'hex', 'base64']) {
  check('fs write+read ' + name, () => {
    fs.writeFileSync('enc/f', 'A9', name);
    return fs.readFileSync('enc/f').toString('hex') + ' -> ' + fs.readFileSync('enc/f', name);
  });
}
// StringDecoder must hold a split multi-byte character, like TextDecoder does.
check('StringDecoder split utf8', () => {
  const decoder = new StringDecoder('utf8');
  return JSON.stringify(decoder.write(Buffer.from([0xe2, 0x82]))) + '+' +
         JSON.stringify(decoder.write(Buffer.from([0xac])));
});
check('StringDecoder utf16le split', () => {
  const decoder = new StringDecoder('utf16le');
  return JSON.stringify(decoder.write(Buffer.from([0x34]))) + '+' +
         JSON.stringify(decoder.write(Buffer.from([0xd8, 0x1e, 0xdd])));
});

(async () => {
  // A stream's setEncoding across every name.
  for (const name of ['utf8', 'latin1', 'hex', 'base64']) {
    await new Promise(resolve => {
      const stream = new Readable({ read() {} });
      stream.setEncoding(name);
      stream.push(Buffer.from([0xc3, 0xa9]));
      stream.push(null);
      const parts = [];
      stream.on('data', c => parts.push(c));
      stream.on('end', () => { say('stream setEncoding ' + name, JSON.stringify(parts.join(''))); resolve(); });
    });
  }
  fs.rmSync('enc', { recursive: true, force: true });
  console.log(out.join('\n'));
  process.exit(0);
})();
