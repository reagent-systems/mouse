'use strict';
// Every stream lifecycle, in the two things a caller can observe: the ORDER of the events and
// the state flags left behind. Both matter and neither is checked by a fixture that only asks
// whether the bytes arrived — the defect that motivated this sweep was a duplex announcing
// 'close' while its writable half was still open, which no throughput test can see.
const { Readable, Writable, Duplex, Transform, PassThrough, pipeline, finished } = require('stream');

function settle() { return new Promise((resolve) => setTimeout(resolve, 60)); }

// Every event a stream can emit about its own lifecycle, recorded in arrival order. 'readable'
// is NOT in this list on purpose: attaching a listener for it takes the stream out of flowing
// mode, so a watcher that always listens would be testing that one rule everywhere instead of
// the lifecycle. The rule gets its own scenarios below.
const WATCHED = ['data', 'end', 'finish', 'close', 'error', 'aborted', 'pause', 'resume', 'drain', 'pipe', 'unpipe'];
// `quiet` leaves the 'data' listener off. An observer that attaches one puts the stream into
// flowing mode, which is the very thing a read()-based or iterator-based scenario is testing —
// the watcher would be changing the mode of what it watches.
function watch(stream, tag, events, quiet) {
  for (const name of WATCHED) {
    if (quiet && name === 'data') continue;
    stream.on(name, (arg) => {
      if (name === 'error') events.push(tag + ':error(' + (arg && arg.code ? arg.code : 'plain') + ')');
      else if (name === 'data') events.push(tag + ':data');
      else events.push(tag + ':' + name);
    });
  }
  return stream;
}

// The flags a caller branches on. `undefined` is reported as-is: a missing flag is a real
// difference from node, not a formatting detail.
function flags(stream) {
  const names = ['destroyed', 'closed', 'readable', 'writable', 'readableEnded', 'writableEnded',
                 'writableFinished', 'readableAborted', 'readableDidRead', 'writableCorked',
                 'readableFlowing', 'readableLength', 'writableLength'];
  const out = [];
  for (const name of names) {
    let value;
    try { value = stream[name]; } catch (error) { value = 'throws'; }
    if (value === undefined) value = 'undef';
    else if (value && typeof value === 'object') value = 'object';
    out.push(name + '=' + String(value));
  }
  const errored = stream.errored;
  out.push('errored=' + (errored ? (errored.code || 'plain') : String(errored)));
  return out.join(' ');
}

// With two streams in play the events are grouped PER STREAM. Each stream's own order is a
// contract; the interleaving between two independent streams is tick scheduling, which node
// does not specify and which would make this sweep assert an implementation detail.
function record(name, events, stream) {
  const tags = [];
  for (const event of events) {
    const tag = event.indexOf(':') > 0 ? event.slice(0, event.indexOf(':')) : '+';
    if (!tags.includes(tag)) tags.push(tag);
  }
  let text;
  if (tags.length > 1) {
    text = tags.map((tag) => tag + '[' + events
      .filter((event) => (event.indexOf(':') > 0 ? event.slice(0, event.indexOf(':')) : '+') === tag)
      .join(',') + ']').join(' ');
  } else {
    text = events.join(',');
  }
  console.log(name + '\t' + text + '\t' + flags(stream));
}

async function scenario(name, build) {
  const events = [];
  let subject;
  try { subject = await build(events); }
  catch (error) { console.log(name + '\tTHREW:' + (error && (error.code || error.message)) + '\t-'); return; }
  await settle();
  record(name, events, subject);
}

async function main() {
  // ---- Readable: the ordinary end, and what it leaves behind -----------------------------
  await scenario('readable-end', async (events) => {
    const r = watch(new Readable({ read() {} }), 'r', events);
    r.push('a'); r.push('b'); r.push(null);
    r.resume();
    return r;
  });

  await scenario('readable-end-noautodestroy', async (events) => {
    const r = watch(new Readable({ read() {}, autoDestroy: false }), 'r', events);
    r.push('a'); r.push(null);
    r.resume();
    return r;
  });

  // Never read: node holds the data and never ends, and the flags say so.
  await scenario('readable-unread', async (events) => {
    const r = watch(new Readable({ read() {} }), 'r', events);
    r.push('a'); r.push(null);
    return r;
  });

  await scenario('readable-destroy', async (events) => {
    const r = watch(new Readable({ read() {} }), 'r', events);
    r.push('a');
    r.destroy();
    return r;
  });

  await scenario('readable-destroy-error', async (events) => {
    const r = watch(new Readable({ read() {} }), 'r', events);
    r.push('a');
    r.destroy(Object.assign(new Error('cut'), { code: 'ECUT' }));
    return r;
  });

  // Destroying twice must not emit a second close, and the first error stands.
  await scenario('readable-destroy-twice', async (events) => {
    const r = watch(new Readable({ read() {} }), 'r', events);
    r.destroy(Object.assign(new Error('first'), { code: 'EFIRST' }));
    r.destroy(Object.assign(new Error('second'), { code: 'ESECOND' }));
    return r;
  });

  await scenario('readable-push-after-eof', async (events) => {
    const r = watch(new Readable({ read() {} }), 'r', events);
    r.push(null);
    r.resume();
    try { r.push('late'); events.push('push-returned'); }
    catch (error) { events.push('push-threw:' + (error && error.code)); }
    return r;
  });

  // ---- the two read modes, which are mutually exclusive -----------------------------------
  // A 'readable' listener takes the stream OUT of flowing mode: 'data' stops arriving and the
  // consumer is expected to call read(). A stream that keeps flowing anyway hands chunks to a
  // consumer that has not asked for them, and the read() it does call returns nothing.
  await scenario('mode-readable-listener', async (events) => {
    const r = watch(new Readable({ read() {} }), 'r', events, true);
    r.on('readable', () => {
      let chunk;
      while ((chunk = r.read()) !== null) events.push('read:' + chunk);
    });
    r.push('a'); r.push('b'); r.push(null);
    return r;
  });

  await scenario('mode-readable-then-resume', async (events) => {
    const r = watch(new Readable({ read() {} }), 'r', events);
    r.on('readable', () => events.push('readable-fired'));
    r.resume();
    r.push('a'); r.push(null);
    return r;
  });

  await scenario('mode-data-then-readable', async (events) => {
    const r = watch(new Readable({ read() {} }), 'r', events);
    r.on('data', (chunk) => events.push('data-listener:' + chunk));
    r.on('readable', () => events.push('readable-fired'));
    r.push('a'); r.push(null);
    return r;
  });

  await scenario('mode-pause-resume', async (events) => {
    const r = watch(new Readable({ read() {} }), 'r', events);
    r.push('a');
    r.pause();
    r.push('b');
    setTimeout(() => { events.push('--resuming'); r.resume(); r.push(null); }, 10);
    return r;
  });

  // ---- Writable ---------------------------------------------------------------------------
  await scenario('writable-end', async (events) => {
    const w = watch(new Writable({ write(chunk, enc, cb) { cb(); } }), 'w', events);
    w.write('a'); w.write('b');
    w.end();
    return w;
  });

  await scenario('writable-end-noautodestroy', async (events) => {
    const w = watch(new Writable({ write(chunk, enc, cb) { cb(); }, autoDestroy: false }), 'w', events);
    w.end('a');
    return w;
  });

  await scenario('writable-end-callback', async (events) => {
    const w = watch(new Writable({ write(chunk, enc, cb) { cb(); } }), 'w', events);
    w.write('a', () => events.push('write-cb'));
    w.end('b', () => events.push('end-cb'));
    return w;
  });

  await scenario('writable-write-after-end', async (events) => {
    const w = watch(new Writable({ write(chunk, enc, cb) { cb(); } }), 'w', events);
    w.end('a');
    const ok = w.write('late');
    events.push('write-returned:' + ok);
    return w;
  });

  await scenario('writable-destroy', async (events) => {
    const w = watch(new Writable({ write(chunk, enc, cb) { cb(); } }), 'w', events);
    w.write('a');
    w.destroy();
    return w;
  });

  await scenario('writable-error-in-write', async (events) => {
    const w = watch(new Writable({ write(chunk, enc, cb) { cb(Object.assign(new Error('nope'), { code: 'EWRITE' })); } }), 'w', events);
    w.write('a');
    return w;
  });

  // ---- Duplex: the half-open rules --------------------------------------------------------
  // The readable half ending must NOT close a duplex whose writable half is still open.
  await scenario('duplex-read-side-only', async (events) => {
    const d = watch(new Duplex({ read() {}, write(chunk, enc, cb) { cb(); } }), 'd', events);
    d.push('a'); d.push(null);
    d.resume();
    return d;
  });

  await scenario('duplex-write-side-only', async (events) => {
    const d = watch(new Duplex({ read() {}, write(chunk, enc, cb) { cb(); } }), 'd', events);
    d.end('a');
    return d;
  });

  await scenario('duplex-both-sides', async (events) => {
    const d = watch(new Duplex({ read() {}, write(chunk, enc, cb) { cb(); } }), 'd', events);
    d.push(null);
    d.resume();
    d.end('a');
    return d;
  });

  await scenario('duplex-half-open-false', async (events) => {
    const d = watch(new Duplex({ read() {}, write(chunk, enc, cb) { cb(); }, allowHalfOpen: false }), 'd', events);
    d.push(null);
    d.resume();
    return d;
  });

  // ---- Transform and PassThrough ----------------------------------------------------------
  await scenario('transform-through', async (events) => {
    const t = watch(new Transform({ transform(chunk, enc, cb) { cb(null, chunk); } }), 't', events);
    t.resume();
    t.end('a');
    return t;
  });

  await scenario('transform-flush', async (events) => {
    const t = watch(new Transform({
      transform(chunk, enc, cb) { cb(null, chunk); },
      flush(cb) { events.push('flush'); cb(null, 'tail'); },
    }), 't', events);
    t.resume();
    t.end('a');
    return t;
  });

  await scenario('transform-error', async (events) => {
    const t = watch(new Transform({ transform(chunk, enc, cb) { cb(Object.assign(new Error('bad'), { code: 'ETRANS' })); } }), 't', events);
    t.resume();
    t.end('a');
    return t;
  });

  // ---- pipe: the events on BOTH ends ------------------------------------------------------
  await scenario('pipe-to-end', async (events) => {
    const src = watch(new Readable({ read() {} }), 'src', events);
    const dst = watch(new PassThrough(), 'dst', events);
    dst.resume();
    src.pipe(dst);
    src.push('a'); src.push(null);
    return dst;
  });

  await scenario('pipe-unpipe', async (events) => {
    const src = watch(new Readable({ read() {} }), 'src', events);
    const dst = watch(new PassThrough(), 'dst', events);
    src.pipe(dst);
    src.unpipe(dst);
    src.push(null);
    src.resume();
    return src;
  });

  await scenario('pipe-noend', async (events) => {
    const src = watch(new Readable({ read() {} }), 'src', events);
    const dst = watch(new PassThrough(), 'dst', events);
    dst.resume();
    src.pipe(dst, { end: false });
    src.push('a'); src.push(null);
    return dst;
  });

  // ---- pipeline and finished --------------------------------------------------------------
  await scenario('pipeline-ok', async (events) => {
    const src = new Readable({ read() {} });
    const mid = new PassThrough();
    const dst = watch(new PassThrough(), 'dst', events);
    dst.resume();
    pipeline(src, mid, dst, (error) => events.push('pipeline-cb:' + (error ? (error.code || 'plain') : 'null')));
    src.push('a'); src.push(null);
    return dst;
  });

  await scenario('pipeline-error', async (events) => {
    const src = new Readable({ read() {} });
    const dst = watch(new PassThrough(), 'dst', events);
    dst.resume();
    pipeline(src, dst, (error) => events.push('pipeline-cb:' + (error ? (error.code || 'plain') : 'null')));
    src.destroy(Object.assign(new Error('gone'), { code: 'EGONE' }));
    return dst;
  });

  await scenario('finished-helper', async (events) => {
    const r = watch(new Readable({ read() {} }), 'r', events);
    finished(r, (error) => events.push('finished-cb:' + (error ? (error.code || 'plain') : 'null')));
    r.push('a'); r.push(null);
    r.resume();
    return r;
  });

  await scenario('finished-on-destroy', async (events) => {
    const r = watch(new Readable({ read() {} }), 'r', events);
    finished(r, (error) => events.push('finished-cb:' + (error ? (error.code || 'plain') : 'null')));
    r.destroy(Object.assign(new Error('stop'), { code: 'ESTOP' }));
    return r;
  });

  // ---- Readable.from and async iteration --------------------------------------------------
  await scenario('readable-from', async (events) => {
    const r = watch(Readable.from(['a', 'b']), 'r', events, true);
    for await (const chunk of r) events.push('iterated:' + chunk);
    return r;
  });

  await scenario('readable-async-iterator-break', async (events) => {
    const r = watch(Readable.from(['a', 'b', 'c']), 'r', events, true);
    for await (const chunk of r) { events.push('iterated:' + chunk); break; }
    return r;
  });

}

main().catch((error) => { console.log('CORPUS FAILED: ' + (error && (error.stack || error.message))); });
