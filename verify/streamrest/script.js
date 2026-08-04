// What the instance-shape sweep left on the stream classes: unpipe, setDefaultEncoding, and the
// introspection getters. unpipe is the one that matters — real code stops a pipe mid-flight
// (proxying, tar, aborting a download), and today that is a TypeError.
const { Readable, Writable, PassThrough } = require('stream');
const out = [];
const say = (l, v) => out.push(l + ': ' + v);
const check = (l, fn) => { try { say(l, fn()); } catch (e) { say(l, 'THREW ' + String(e.message).slice(0, 40)); } };
const race = (label, build) => new Promise(resolve => {
  let settled = false;
  const finish = v => { if (!settled) { settled = true; say(label, v); resolve(); } };
  setTimeout(() => finish('NEVER SETTLED'), 900);
  try { build(finish); } catch (e) { finish('THREW ' + String(e.message).slice(0, 40)); }
});

check('methods present', () => {
  const r = new Readable({ read() {} });
  const w = new Writable({ write(c, e, cb) { cb(); } });
  return ['unpipe', 'wrap', 'compose'].filter(n => typeof r[n] !== 'function').join(',') +
         '|' + ['setDefaultEncoding'].filter(n => typeof w[n] !== 'function').join(',');
});
check('readable getters', () => {
  const r = new Readable({ read() {}, highWaterMark: 99 });
  return [r.readableHighWaterMark, r.readableLength, r.readableEnded, r.readableFlowing,
          r.readableObjectMode, r.readableEncoding].join('|');
});
check('writable getters', () => {
  const w = new Writable({ write(c, e, cb) { cb(); }, highWaterMark: 77 });
  return [w.writableHighWaterMark, w.writableLength, w.writableEnded, w.writableFinished,
          w.writableObjectMode, w.writableNeedDrain].join('|');
});
check('readableEncoding after setEncoding', () => {
  const r = new Readable({ read() {} });
  r.setEncoding('hex');
  return String(r.readableEncoding);
});

(async () => {
  // unpipe must actually STOP the flow: what arrives after it must not reach the old sink.
  await race('unpipe stops delivery', finish => {
    const source = new Readable({ read() {} });
    const got = [];
    const sink = new Writable({ write(c, e, cb) { got.push(String(c)); cb(); } });
    source.pipe(sink);
    source.push('before');
    setTimeout(() => {
      source.unpipe(sink);
      source.push('after');
      setTimeout(() => finish(JSON.stringify(got)), 120);
    }, 100);
  });
  // unpipe with no argument detaches every destination.
  await race('unpipe all', finish => {
    const source = new Readable({ read() {} });
    const got = [];
    const a = new Writable({ write(c, e, cb) { got.push('a:' + c); cb(); } });
    const b = new Writable({ write(c, e, cb) { got.push('b:' + c); cb(); } });
    source.pipe(a); source.pipe(b);
    source.push('one');
    setTimeout(() => {
      source.unpipe();
      source.push('two');
      setTimeout(() => finish(JSON.stringify(got.sort())), 120);
    }, 100);
  });
  // The 'unpipe' event fires on the destination.
  await race('unpipe event', finish => {
    const source = new Readable({ read() {} });
    const sink = new PassThrough();
    sink.on('unpipe', () => finish('fired'));
    source.pipe(sink);
    setTimeout(() => source.unpipe(sink), 60);
  });
  await race('writableLength grows', finish => {
    const w = new Writable({ highWaterMark: 100, write(c, e, cb) { setTimeout(cb, 200); } });
    w.write('12345');
    setTimeout(() => finish(String(w.writableLength)), 40);
  });
  console.log(out.join('\n'));
  process.exit(0);
})();
