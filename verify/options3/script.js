// Options detector, third batch. Applying the rules the last two batches taught: every check is
// isolated so one throw cannot hide the rest, and every async check races a fallback so an
// ignored option reports a wrong answer instead of hanging.
const fs = require('fs');
const crypto = require('crypto');
const util = require('util');
const events = require('events');
const querystring = require('querystring');
const out = [];
const say = (l, v) => out.push(l + ': ' + v);
const check = (l, fn) => { try { say(l, fn()); } catch (e) { say(l, 'THREW ' + String(e.message).slice(0, 45)); } };
const race = (label, build) => new Promise(resolve => {
  let settled = false;
  const finish = v => { if (!settled) { settled = true; say(label, v); resolve(); } };
  setTimeout(() => finish('NO EFFECT (fell through)'), 1200);
  try { build(finish); } catch (e) { finish('THREW ' + String(e.message).slice(0, 45)); }
});

fs.rmSync('o3', { recursive: true, force: true });
fs.mkdirSync('o3');
fs.writeFileSync('o3/data.bin', '0123456789');

// Buffer.from with an offset and length VIEWS a range — ignoring them returns the wrong bytes.
check('Buffer.from offset+length', () => {
  const backing = new Uint8Array([1, 2, 3, 4, 5]).buffer;
  return JSON.stringify(Array.from(Buffer.from(backing, 1, 3)));
});
// util.inspect depth: ignoring it prints the whole tree where node prints [Object].
check('inspect depth 0', () => util.inspect({ a: { b: { c: 1 } } }, { depth: 0 }));
check('inspect depth default', () => util.inspect({ a: { b: { c: { d: 1 } } } }));
// querystring maxKeys caps how much of a hostile query string is parsed.
check('querystring maxKeys', () => Object.keys(querystring.parse('a=1&b=2&c=3', '&', '=', { maxKeys: 2 })).length);
// An authTagLength shorter than the default must be honoured for GCM.
check('cipher authTagLength', () => {
  const c = crypto.createCipheriv('aes-256-gcm', Buffer.alloc(32), Buffer.alloc(12), { authTagLength: 12 });
  c.update('x'); c.final();
  return c.getAuthTag().length;
});

(async () => {
  // A byte RANGE read: tar readers and HTTP range responses depend on it, and an ignored
  // start/end quietly returns the whole file — wrong data rather than an error.
  await race('createReadStream start+end', finish => {
    const chunks = [];
    const stream = fs.createReadStream('o3/data.bin', { start: 2, end: 5 });
    stream.on('data', c => chunks.push(c));
    stream.on('end', () => finish(JSON.stringify(Buffer.concat(chunks).toString())));
    stream.on('error', e => finish('error ' + e.code));
  });
  await race('createReadStream encoding', finish => {
    const parts = [];
    const stream = fs.createReadStream('o3/data.bin', { encoding: 'utf8' });
    stream.on('data', c => parts.push(typeof c));
    stream.on('end', () => finish(JSON.stringify(parts)));
    stream.on('error', e => finish('error ' + e.code));
  });
  // createWriteStream with flags 'a' must append, not truncate.
  await race('createWriteStream flags a', finish => {
    const stream = fs.createWriteStream('o3/data.bin', { flags: 'a' });
    stream.end('AB', () => finish(JSON.stringify(fs.readFileSync('o3/data.bin', 'utf8'))));
    stream.on('error', e => finish('error ' + e.code));
  });
  // events.once with a signal must reject when aborted rather than waiting forever.
  await race('events.once signal', finish => {
    const controller = new AbortController();
    const emitter = new events.EventEmitter();
    events.once(emitter, 'never', { signal: controller.signal })
      .then(() => finish('resolved'))
      .catch(e => finish(e.name === 'AbortError' ? 'aborted' : 'error:' + e.code));
    setTimeout(() => controller.abort(), 100);
  });
  fs.rmSync('o3', { recursive: true, force: true });
  console.log(out.join('\n'));
  process.exit(0);
})();
