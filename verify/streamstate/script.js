// Stream STATE values across a lifecycle. The shape sweep proves a property exists; it cannot
// see one reporting the wrong value. Two in-flight bugs (highWaterMark, then writableLength)
// came from state going stale when a value moved between places, so this checks the values
// themselves at each point a program would read them.
const { Readable, Writable, PassThrough } = require('stream');
const out = [];
const say = (l, v) => out.push(l + ': ' + v);
const snapR = r => [r.readableFlowing, r.readableLength, r.readableEnded, r.destroyed, r.readable].join('|');
const snapW = w => [w.writableLength, w.writableEnded, w.writableFinished, w.writableCorked,
                    w.destroyed, w.writable, w.writableNeedDrain].join('|');

(async () => {
  // Readable, through its whole life.
  const r = new Readable({ read() {} });
  say('readable fresh', snapR(r));
  r.push('abc');
  say('after push', snapR(r));
  r.resume();
  await new Promise(res => setTimeout(res, 30));
  say('after resume+drain', snapR(r));
  r.push(null);
  await new Promise(res => setTimeout(res, 30));
  say('after EOF', snapR(r));

  const r2 = new Readable({ read() {} });
  r2.destroy();
  await new Promise(res => setTimeout(res, 30));
  say('destroyed readable', snapR(r2));

  // Writable, including a slow write so the in-flight window is visible.
  let release = null;
  const w = new Writable({ highWaterMark: 4, write(c, e, cb) { release = cb; } });
  say('writable fresh', snapW(w));
  const accepted = w.write('12345');
  say('write returned', String(accepted));
  say('during slow write', snapW(w));
  release();
  await new Promise(res => setTimeout(res, 30));
  say('after write completes', snapW(w));
  w.cork();
  say('corked', snapW(w));
  w.uncork();
  w.end();
  await new Promise(res => setTimeout(res, 30));
  say('after end', snapW(w));

  const w2 = new Writable({ write(c, e, cb) { cb(); } });
  w2.destroy();
  await new Promise(res => setTimeout(res, 30));
  say('destroyed writable', snapW(w2));

  // A Duplex reports both halves independently.
  const p = new PassThrough();
  p.write('x');
  say('passthrough after write', snapR(p) + ' / ' + snapW(p));
  p.end();
  await new Promise(res => setTimeout(res, 30));
  say('passthrough after end', snapW(p));
  console.log(out.join('\n'));
  process.exit(0);
})();
