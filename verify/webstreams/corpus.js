'use strict';
// Web streams: what a fetch body IS, and the only bridge between node streams and everything
// written for the platform. The rules that matter here are the ones a caller cannot work around
// — a stream is LOCKED to one reader, a controller reports how much it wants, and cancelling one
// branch of a tee must not starve the other. Getting those wrong does not fail loudly; it hangs.
const { Readable, Writable, Duplex } = require('stream');

function line(name, value) { console.log(name + '\t' + value); }
function show(error) {
  if (!error) return String(error);
  if (typeof error !== 'object') return typeof error + ':' + String(error);
  return (error.name || 'Error') + '/' + (error.code || 'no-code');
}
function attempt(name, fn) {
  try { line(name, String(fn())); }
  catch (error) { line(name, 'THREW ' + show(error)); }
}

// ---- the surface that is supposed to exist ------------------------------------------------------
attempt('globals-present', () => {
  return ['ReadableStream', 'WritableStream', 'TransformStream', 'ByteLengthQueuingStrategy',
          'CountQueuingStrategy', 'TextEncoderStream', 'TextDecoderStream',
          'CompressionStream', 'DecompressionStream']
    .map((name) => name + '=' + typeof globalThis[name]).join(' ');
});

attempt('node-bridges', () => {
  return ['toWeb', 'fromWeb'].map((name) => 'Readable.' + name + '=' + typeof Readable[name]).join(' ')
    + ' Writable.toWeb=' + typeof Writable.toWeb
    + ' Writable.fromWeb=' + typeof Writable.fromWeb
    + ' Duplex.toWeb=' + typeof Duplex.toWeb;
});

// ---- locking, which is the rule everything else rests on -------------------------------------
attempt('locked-to-one-reader', () => {
  const stream = new ReadableStream({ start(c) { c.close(); } });
  const before = stream.locked;
  const reader = stream.getReader();
  const during = stream.locked;
  let second = 'allowed a second reader';
  try { stream.getReader(); } catch (error) { second = 'THREW ' + (error && error.name); }
  reader.releaseLock();
  return before + ' -> ' + during + ' -> ' + stream.locked + ' | ' + second;
});

attempt('read-after-release', () => {
  const stream = new ReadableStream({ start(c) { c.enqueue('a'); c.close(); } });
  const reader = stream.getReader();
  reader.releaseLock();
  try {
    const pending = reader.read();
    if (pending && typeof pending.catch === 'function') pending.catch(() => {});
    return 'read allowed (rejects rather than throwing)';
  } catch (error) { return 'THREW ' + (error && error.name); }
});

attempt('writer-lock', () => {
  const stream = new WritableStream({ write() {} });
  const writer = stream.getWriter();
  let second = 'allowed a second writer';
  try { stream.getWriter(); } catch (error) { second = 'THREW ' + (error && error.name); }
  const lockedNow = stream.locked;
  writer.releaseLock();
  return lockedNow + ' -> ' + stream.locked + ' | ' + second;
});

// ---- the controller ------------------------------------------------------------------------------
attempt('controller-desiredSize', () => {
  let sizes = [];
  const stream = new ReadableStream({
    start(controller) {
      sizes.push(controller.desiredSize);
      controller.enqueue('a');
      sizes.push(controller.desiredSize);
      controller.close();
      sizes.push(controller.desiredSize);
    },
  });
  return sizes.join(',');
});

attempt('enqueue-after-close', () => {
  let outcome = 'no error';
  new ReadableStream({
    start(controller) {
      controller.close();
      try { controller.enqueue('late'); } catch (error) { outcome = 'THREW ' + (error && error.name); }
    },
  });
  return outcome;
});

attempt('close-twice', () => {
  let outcome = 'no error';
  new ReadableStream({
    start(controller) {
      controller.close();
      try { controller.close(); } catch (error) { outcome = 'THREW ' + (error && error.name); }
    },
  });
  return outcome;
});

attempt('highWaterMark-controls-pull', () => {
  let pulls = 0;
  new ReadableStream({ pull() { pulls += 1; } }, new CountQueuingStrategy({ highWaterMark: 0 }));
  return 'pulls with hwm 0 = ' + pulls;
});

// ---- reading ---------------------------------------------------------------------------------------
async function asyncScenarios() {
  const namedThen = async (name, fn) => {
    try { line(name, String(await fn())); }
    catch (error) { line(name, 'REJECTED ' + show(error)); }
  };

  await namedThen('read-to-completion', async () => {
    const stream = new ReadableStream({ start(c) { c.enqueue('a'); c.enqueue('b'); c.close(); } });
    const reader = stream.getReader();
    const got = [];
    for (;;) {
      const result = await reader.read();
      got.push(result.done ? 'done' : result.value);
      if (result.done) break;
    }
    return got.join(',');
  });

  await namedThen('reader-closed-promise', async () => {
    const stream = new ReadableStream({ start(c) { c.close(); } });
    const reader = stream.getReader();
    await reader.closed;
    return 'closed resolved';
  });

  await namedThen('error-propagates', async () => {
    const stream = new ReadableStream({ start(c) { c.error(new TypeError('bad source')); } });
    const reader = stream.getReader();
    try { await reader.read(); return 'read resolved'; }
    catch (error) { return 'read rejected ' + (error && error.name); }
  });

  await namedThen('cancel-reaches-the-source', async () => {
    let seen = 'never cancelled';
    const stream = new ReadableStream({ start() {}, cancel(reason) { seen = 'cancelled:' + reason; } });
    const reader = stream.getReader();
    await reader.cancel('caller asked');
    return seen;
  });

  await namedThen('async-iteration', async () => {
    const stream = new ReadableStream({ start(c) { c.enqueue(1); c.enqueue(2); c.enqueue(3); c.close(); } });
    const got = [];
    for await (const value of stream) got.push(value);
    return got.join(',');
  });

  // Both branches of a tee must see EVERY chunk, independently and in order. A shared cursor
  // makes one branch eat the other's data, and the loss is silent.
  await namedThen('tee-both-branches', async () => {
    const stream = new ReadableStream({ start(c) { c.enqueue('x'); c.enqueue('y'); c.close(); } });
    const [left, right] = stream.tee();
    const drain = async (branch) => {
      const got = [];
      const reader = branch.getReader();
      for (;;) { const r = await reader.read(); if (r.done) break; got.push(r.value); }
      return got.join('');
    };
    const [a, b] = await Promise.all([drain(left), drain(right)]);
    return a + '|' + b + ' lockedOriginal=' + stream.locked;
  });

  await namedThen('pipeThrough-text', async () => {
    if (typeof TextEncoderStream !== 'function' || typeof TextDecoderStream !== 'function') return 'absent';
    const source = new ReadableStream({ start(c) { c.enqueue('héllo'); c.close(); } });
    const piped = source.pipeThrough(new TextEncoderStream()).pipeThrough(new TextDecoderStream());
    const got = [];
    for await (const value of piped) got.push(value);
    return got.join('');
  });

  await namedThen('pipeTo-writable', async () => {
    const written = [];
    const source = new ReadableStream({ start(c) { c.enqueue('a'); c.enqueue('b'); c.close(); } });
    const sink = new WritableStream({ write(chunk) { written.push(chunk); }, close() { written.push('closed'); } });
    await source.pipeTo(sink);
    return written.join(',');
  });

  await namedThen('transform-stream', async () => {
    const upper = new TransformStream({
      transform(chunk, controller) { controller.enqueue(String(chunk).toUpperCase()); },
      flush(controller) { controller.enqueue('!'); },
    });
    const source = new ReadableStream({ start(c) { c.enqueue('ab'); c.enqueue('cd'); c.close(); } });
    const got = [];
    for await (const value of source.pipeThrough(upper)) got.push(value);
    return got.join(',');
  });

  await namedThen('writer-write-and-close', async () => {
    const written = [];
    const stream = new WritableStream({ write(chunk) { written.push(chunk); }, close() { written.push('closed'); } });
    const writer = stream.getWriter();
    await writer.ready;
    await writer.write('one');
    await writer.write('two');
    await writer.close();
    return written.join(',');
  });

  await namedThen('writer-abort', async () => {
    let reason = 'not aborted';
    const stream = new WritableStream({ write() {}, abort(r) { reason = 'aborted:' + r; } });
    const writer = stream.getWriter();
    await writer.abort('caller gave up');
    return reason;
  });

  // The bridges. node code hands a Readable to something that wants a web stream and back, and
  // a body from fetch arrives as a web stream that node code then pipes.
  await namedThen('Readable.toWeb', async () => {
    if (typeof Readable.toWeb !== 'function') return 'absent';
    const web = Readable.toWeb(Readable.from(['a', 'b']));
    const got = [];
    for await (const chunk of web) got.push(String(chunk));
    return got.join(',');
  });

  // Joined with nothing on purpose: a binary node stream may coalesce two enqueued strings into
  // one Buffer, and chunk boundaries are exactly what a byte stream does not promise. The
  // objectMode case below asserts the boundaries, where they ARE meaningful.
  await namedThen('Readable.fromWeb', async () => {
    if (typeof Readable.fromWeb !== 'function') return 'absent';
    const web = new ReadableStream({ start(c) { c.enqueue('one'); c.enqueue('two'); c.close(); } });
    const node = Readable.fromWeb(web);
    const got = [];
    for await (const chunk of node) got.push(String(chunk));
    return got.join('');
  });

  await namedThen('Readable.fromWeb-objectMode', async () => {
    if (typeof Readable.fromWeb !== 'function') return 'absent';
    const web = new ReadableStream({ start(c) { c.enqueue({ n: 1 }); c.enqueue({ n: 2 }); c.close(); } });
    const node = Readable.fromWeb(web, { objectMode: true });
    const got = [];
    for await (const chunk of node) got.push(JSON.stringify(chunk));
    return got.join(',');
  });

  await namedThen('Writable.toWeb', async () => {
    if (typeof Writable.toWeb !== 'function') return 'absent';
    const seen = [];
    const node = new Writable({ write(chunk, enc, cb) { seen.push(String(chunk)); cb(); } });
    const web = Writable.toWeb(node);
    const writer = web.getWriter();
    await writer.write(Buffer.from('through'));
    await writer.close();
    return seen.join(',');
  });

  await namedThen('round-trip', async () => {
    if (typeof Readable.toWeb !== 'function' || typeof Readable.fromWeb !== 'function') return 'absent';
    const back = Readable.fromWeb(Readable.toWeb(Readable.from(['round', 'trip'])));
    const got = [];
    for await (const chunk of back) got.push(String(chunk));
    return got.join('');
  });
}

asyncScenarios().then(() => line('done', 'yes'),
                      (error) => line('done', 'FAILED ' + show(error)));
