// The SIGNAL audit: every API node lets you abort. Two of the last three findings were this same
// defect in different places, and an ignored signal is the worst kind — the caller's only way out
// becomes a permanent wait. Sweeping the class instead of meeting it again later.
const fs = require('fs');
const events = require('events');
const stream = require('stream');
const readline = require('readline');
const timers = require('timers/promises');
const out = [];
const say = (l, v) => out.push(l + ': ' + v);
const race = (label, build) => new Promise(resolve => {
  let settled = false;
  const finish = v => { if (!settled) { settled = true; say(label, v); resolve(); } };
  setTimeout(() => finish('NEVER SETTLED'), 1000);
  try { build(finish); } catch (e) { finish('THREW ' + String(e.message).slice(0, 40)); }
});
const isAbort = e => (e && (e.name === 'AbortError' || e.code === 'ABORT_ERR')) ? 'aborted' : 'other:' + (e && (e.code || e.name));

fs.rmSync('sig', { recursive: true, force: true });
fs.mkdirSync('sig');
fs.writeFileSync('sig/f.txt', 'x');

(async () => {
  // AbortSignal's own constructors, which everything below leans on.
  await race('AbortSignal.timeout fires', finish => {
    const signal = AbortSignal.timeout(80);
    if (typeof signal.addEventListener !== 'function') return finish('no addEventListener');
    signal.addEventListener('abort', () => finish('aborted'));
  });
  await race('AbortSignal.any fires', finish => {
    const controller = new AbortController();
    const any = AbortSignal.any([controller.signal, new AbortController().signal]);
    any.addEventListener('abort', () => finish('aborted'));
    setTimeout(() => controller.abort(), 60);
  });

  // timers/promises: a sleep you can cancel.
  await race('timers.setTimeout signal', finish => {
    const controller = new AbortController();
    timers.setTimeout(5000, null, { signal: controller.signal })
      .then(() => finish('resolved')).catch(e => finish(isAbort(e)));
    setTimeout(() => controller.abort(), 80);
  });

  // events.on (the async-iterator form) must end when aborted.
  await race('events.on signal', finish => {
    const controller = new AbortController();
    const emitter = new events.EventEmitter();
    (async () => {
      try { for await (const _ of events.on(emitter, 'never', { signal: controller.signal })) {} finish('ended'); }
      catch (e) { finish(isAbort(e)); }
    })();
    setTimeout(() => controller.abort(), 80);
  });

  // fs reads and writes take one too.
  await race('fs.readFile signal', finish => {
    const controller = new AbortController();
    controller.abort();
    fs.readFile('sig/f.txt', { signal: controller.signal }, error => finish(error ? isAbort(error) : 'read anyway'));
  });
  await race('fs.promises.readFile signal', finish => {
    const controller = new AbortController();
    controller.abort();
    fs.promises.readFile('sig/f.txt', { signal: controller.signal })
      .then(() => finish('read anyway')).catch(e => finish(isAbort(e)));
  });
  // A watcher you cannot stop is a leak.
  await race('fs.watch signal closes it', finish => {
    const controller = new AbortController();
    const watcher = fs.watch('sig', { signal: controller.signal });
    watcher.on('close', () => finish('closed'));
    watcher.on('error', () => {});
    setTimeout(() => controller.abort(), 80);
  });

  // stream helpers.
  await race('stream.finished signal', finish => {
    const controller = new AbortController();
    const never = new stream.Readable({ read() {} });
    stream.finished(never, { signal: controller.signal }, error => finish(error ? isAbort(error) : 'finished'));
    setTimeout(() => controller.abort(), 80);
  });
  // The signal form of pipeline is the PROMISE one; node rejects the callback+options order.
  await race('stream/promises pipeline signal', finish => {
    const controller = new AbortController();
    const never = new stream.Readable({ read() {} });
    const sink = new stream.Writable({ write(c, e, cb) { cb(); } });
    require('stream/promises').pipeline(never, sink, { signal: controller.signal })
      .then(() => finish('piped')).catch(e => finish(isAbort(e)));
    setTimeout(() => controller.abort(), 80);
  });

  // readline: an interface that closes when told.
  await race('readline signal closes', finish => {
    const controller = new AbortController();
    const rl = readline.createInterface({ input: new stream.Readable({ read() {} }), signal: controller.signal });
    rl.on('close', () => finish('closed'));
    setTimeout(() => controller.abort(), 80);
  });

  fs.rmSync('sig', { recursive: true, force: true });
  console.log(out.join('\n'));
  process.exit(0);
})();
