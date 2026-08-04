'use strict';
// AbortSignal is the cancellation substrate: timers/promises, events.once, events.on, streams,
// fs and readline all take one, and an existing fixture already checks that those APIs cancel.
// This checks the SIGNAL itself — what a reason is, which listeners fire and in what order, what
// the statics produce, and what a signal that is already aborted does to code that meets it
// late. A cancellation that reports the wrong reason is worse than one that never happens: the
// caller branches on it.
const events = require('events');
const timersPromises = require('timers/promises');

function line(name, value) { console.log(name + '\t' + value); }
function show(error) {
  if (!error) return String(error);
  if (typeof error !== 'object') return typeof error + ':' + String(error);
  return (error.name || 'Error') + '/' + (error.code || 'no-code') + '/' + (error.message || '');
}
function attempt(name, fn) {
  try { line(name, String(fn())); }
  catch (error) { line(name, 'THREW ' + show(error)); }
}

// ---- the controller and its signal ----------------------------------------------------------
attempt('controller-shape', () => {
  const controller = new AbortController();
  return [typeof controller.abort, typeof controller.signal,
          controller.signal === controller.signal,
          typeof controller.signal.addEventListener,
          typeof controller.signal.throwIfAborted].join(',');
});

attempt('signal-tags', () => {
  const controller = new AbortController();
  return [controller.signal[Symbol.toStringTag],
          Object.prototype.toString.call(controller.signal),
          typeof AbortSignal, typeof EventTarget,
          controller.signal instanceof AbortSignal].join(' | ');
});

attempt('default-reason', () => {
  const controller = new AbortController();
  const before = controller.signal.aborted + ',' + String(controller.signal.reason);
  controller.abort();
  return before + ' -> ' + controller.signal.aborted + ',' + show(controller.signal.reason);
});

attempt('custom-reason', () => {
  const controller = new AbortController();
  controller.abort('just a string');
  const first = typeof controller.signal.reason + ':' + controller.signal.reason;
  const other = new AbortController();
  other.abort(Object.assign(new Error('mine'), { code: 'EMINE' }));
  return first + ' | ' + show(other.signal.reason);
});

attempt('abort-is-idempotent', () => {
  const controller = new AbortController();
  let fired = 0;
  controller.signal.addEventListener('abort', () => { fired += 1; });
  controller.abort('first');
  controller.abort('second');
  return fired + ' reason=' + controller.signal.reason;
});

attempt('throwIfAborted', () => {
  const controller = new AbortController();
  let before = 'no throw';
  try { controller.signal.throwIfAborted(); } catch (error) { before = 'THREW'; }
  controller.abort(Object.assign(new Error('stop'), { code: 'ESTOP' }));
  try { controller.signal.throwIfAborted(); return before + ' -> no throw'; }
  catch (error) { return before + ' -> ' + show(error); }
});

// ---- listeners --------------------------------------------------------------------------------
attempt('listener-order', () => {
  const seen = [];
  const controller = new AbortController();
  controller.signal.addEventListener('abort', () => seen.push('listener1'));
  controller.signal.onabort = () => seen.push('onabort');
  controller.signal.addEventListener('abort', () => seen.push('listener2'));
  controller.abort();
  return seen.join(',');
});

attempt('event-object', () => {
  const controller = new AbortController();
  let described = 'never fired';
  controller.signal.addEventListener('abort', function (event) {
    described = event.type + ' target=' + (event.target === controller.signal)
      + ' this=' + (this === controller.signal);
  });
  controller.abort();
  return described;
});

attempt('listener-added-after-abort', () => {
  const controller = new AbortController();
  controller.abort();
  let fired = false;
  controller.signal.addEventListener('abort', () => { fired = true; });
  return 'fired=' + fired;
});

attempt('removeEventListener', () => {
  const controller = new AbortController();
  let fired = 0;
  const listener = () => { fired += 1; };
  controller.signal.addEventListener('abort', listener);
  controller.signal.removeEventListener('abort', listener);
  controller.abort();
  return fired;
});

attempt('once-option', () => {
  const controller = new AbortController();
  let fired = 0;
  controller.signal.addEventListener('abort', () => { fired += 1; }, { once: true });
  controller.abort();
  return fired;
});

attempt('duplicate-listener-added-once', () => {
  const controller = new AbortController();
  let fired = 0;
  const listener = () => { fired += 1; };
  controller.signal.addEventListener('abort', listener);
  controller.signal.addEventListener('abort', listener);
  controller.abort();
  return fired;
});

attempt('onabort-replaces', () => {
  const seen = [];
  const controller = new AbortController();
  controller.signal.onabort = () => seen.push('first');
  controller.signal.onabort = () => seen.push('second');
  controller.abort();
  return seen.join(',') + ' typeof=' + typeof controller.signal.onabort;
});

// ---- the statics --------------------------------------------------------------------------------
attempt('AbortSignal.abort', () => {
  const signal = AbortSignal.abort();
  const withReason = AbortSignal.abort('given');
  return signal.aborted + ' ' + show(signal.reason) + ' | ' + withReason.aborted + ' ' + withReason.reason;
});

attempt('AbortSignal.any-shape', () => {
  const a = new AbortController(), b = new AbortController();
  const composite = AbortSignal.any([a.signal, b.signal]);
  const before = composite.aborted;
  b.abort('from b');
  return before + ' -> ' + composite.aborted + ' reason=' + composite.reason;
});

attempt('AbortSignal.any-already-aborted', () => {
  const already = AbortSignal.abort('was already');
  const composite = AbortSignal.any([new AbortController().signal, already]);
  return composite.aborted + ' reason=' + composite.reason;
});

attempt('AbortSignal.any-empty', () => {
  const composite = AbortSignal.any([]);
  return composite.aborted;
});

attempt('AbortSignal.any-fires-listeners', () => {
  const seen = [];
  const a = new AbortController();
  const composite = AbortSignal.any([a.signal]);
  composite.addEventListener('abort', () => seen.push('composite:' + composite.reason));
  a.abort('cause');
  return seen.join(',');
});

attempt('addAbortListener', () => {
  if (typeof events.addAbortListener !== 'function') return 'absent';
  const controller = new AbortController();
  const seen = [];
  const disposable = events.addAbortListener(controller.signal, () => seen.push('heard'));
  controller.abort();
  return seen.join(',') + ' disposable=' + (disposable && typeof disposable[Symbol.dispose]);
});

// ---- what the rest of the runtime does with one ---------------------------------------------------
async function asyncScenarios() {
  const namedThen = async (name, fn) => {
    try { line(name, String(await fn())); }
    catch (error) { line(name, 'REJECTED ' + show(error)); }
  };

  await namedThen('timeout-signal', async () => {
    const signal = AbortSignal.timeout(10);
    const before = signal.aborted;
    await new Promise((resolve) => setTimeout(resolve, 40));
    return before + ' -> ' + signal.aborted + ' ' + show(signal.reason);
  });

  await namedThen('timers-promises-reason', async () => {
    const controller = new AbortController();
    setTimeout(() => controller.abort(Object.assign(new Error('mine'), { code: 'EMINE' })), 5);
    await timersPromises.setTimeout(200, 'never', { signal: controller.signal });
    return 'resolved anyway';
  });

  await namedThen('timers-promises-default-reason', async () => {
    const controller = new AbortController();
    setTimeout(() => controller.abort(), 5);
    await timersPromises.setTimeout(200, 'never', { signal: controller.signal });
    return 'resolved anyway';
  });

  await namedThen('events.once-with-signal', async () => {
    const emitter = new events.EventEmitter();
    const controller = new AbortController();
    setTimeout(() => controller.abort(), 5);
    await events.once(emitter, 'never', { signal: controller.signal });
    return 'resolved anyway';
  });

  await namedThen('events.once-leaves-nothing-after-abort', async () => {
    const emitter = new events.EventEmitter();
    const controller = new AbortController();
    setTimeout(() => controller.abort(), 5);
    try { await events.once(emitter, 'never', { signal: controller.signal }); } catch (ignored) {}
    return emitter.listenerCount('never') + ',' + emitter.listenerCount('error');
  });

  await namedThen('events.on-with-signal', async () => {
    const emitter = new events.EventEmitter();
    const controller = new AbortController();
    setTimeout(() => controller.abort(), 5);
    const got = [];
    try {
      for await (const value of events.on(emitter, 'tick', { signal: controller.signal })) got.push(value);
    } catch (error) { return 'REJECTED ' + show(error) + ' got=' + got.length; }
    return 'ended cleanly';
  });

  await namedThen('already-aborted-signal-rejects-immediately', async () => {
    const signal = AbortSignal.abort('pre-aborted');
    await timersPromises.setTimeout(200, 'never', { signal: signal });
    return 'resolved anyway';
  });

  await namedThen('timeout-signal-does-not-hold-the-loop', async () => {
    // A long timeout signal must not be a reason for the process to stay alive; if it were,
    // every request with a deadline would keep a CLI running until the deadline passed.
    const signal = AbortSignal.timeout(100000);
    return 'created aborted=' + signal.aborted;
  });
}

asyncScenarios().then(() => line('done', 'yes'),
                      (error) => line('done', 'FAILED ' + show(error)));
