'use strict';
// EventEmitter's OWN semantics, which nothing here has ever checked. The stream sweep found its
// worst defects in machinery every other subsystem sits on; this is the layer under that one.
// What is under test is not "does a listener run" but the rules around it: the order listeners
// run in, what a mutation during an emit does to the emit in flight, what `once` leaves behind,
// which meta-events fire and when, and what happens to an 'error' nobody is listening for.
const EventEmitter = require('events');
const events = require('events');

function line(name, value) { console.log(name + '\t' + value); }
function show(value) {
  if (typeof value === 'symbol') return String(value);
  if (typeof value === 'function') return 'fn:' + (value.name || 'anon');
  if (Array.isArray(value)) return '[' + value.map(show).join(',') + ']';
  if (value instanceof Error) return 'Error(' + (value.code || value.message) + ')';
  if (value && typeof value === 'object') return JSON.stringify(value);
  return String(value);
}
function attempt(name, fn) {
  try { line(name, show(fn())); }
  catch (error) { line(name, 'THREW ' + (error && (error.code || error.message))); }
}

// ---- order, duplicates, and what the methods return -------------------------------------
attempt('order', () => {
  const seen = [];
  const emitter = new EventEmitter();
  emitter.on('x', () => seen.push('a'));
  emitter.on('x', () => seen.push('b'));
  emitter.prependListener('x', () => seen.push('pre'));
  emitter.emit('x');
  return seen;
});

attempt('duplicates-run-twice', () => {
  const seen = [];
  const emitter = new EventEmitter();
  const listener = () => seen.push('l');
  emitter.on('x', listener);
  emitter.on('x', listener);
  emitter.emit('x');
  return seen.length + ' count=' + emitter.listenerCount('x');
});

attempt('removeListener-removes-one', () => {
  const emitter = new EventEmitter();
  const listener = () => {};
  emitter.on('x', listener);
  emitter.on('x', listener);
  emitter.removeListener('x', listener);
  return emitter.listenerCount('x');
});

attempt('methods-return-this', () => {
  const emitter = new EventEmitter();
  const listener = () => {};
  return [emitter.on('a', listener) === emitter, emitter.once('b', listener) === emitter,
          emitter.off('a', listener) === emitter, emitter.removeAllListeners() === emitter,
          emitter.setMaxListeners(5) === emitter].join(',');
});

attempt('emit-return', () => {
  const emitter = new EventEmitter();
  const before = emitter.emit('nobody');
  emitter.on('somebody', () => {});
  return before + ',' + emitter.emit('somebody');
});

attempt('emit-args', () => {
  const emitter = new EventEmitter();
  let got = null;
  emitter.on('x', function (...args) { got = args.length + ':' + args.join('|') + ' this=' + (this === emitter); });
  emitter.emit('x', 1, 2, 3, 4, 5);
  return got;
});

// ---- once ---------------------------------------------------------------------------------
attempt('once-fires-once', () => {
  let count = 0;
  const emitter = new EventEmitter();
  emitter.once('x', () => count++);
  emitter.emit('x'); emitter.emit('x');
  return count + ' left=' + emitter.listenerCount('x');
});

attempt('once-removable-by-original', () => {
  const emitter = new EventEmitter();
  const listener = () => {};
  emitter.once('x', listener);
  emitter.removeListener('x', listener);
  return emitter.listenerCount('x');
});

attempt('once-wrapper-visibility', () => {
  const emitter = new EventEmitter();
  const listener = function named() {};
  emitter.once('x', listener);
  const plain = emitter.listeners('x');
  const raw = emitter.rawListeners('x');
  return 'listeners=' + (plain[0] === listener) + ' raw=' + (raw[0] === listener)
    + ' rawHasListener=' + (raw[0].listener === listener);
});

attempt('once-removed-before-call', () => {
  const emitter = new EventEmitter();
  let inside = null;
  emitter.once('x', () => { inside = emitter.listenerCount('x'); });
  emitter.emit('x');
  return 'countDuringCall=' + inside;
});

attempt('prependOnce', () => {
  const seen = [];
  const emitter = new EventEmitter();
  emitter.on('x', () => seen.push('normal'));
  emitter.prependOnceListener('x', () => seen.push('first'));
  emitter.emit('x'); emitter.emit('x');
  return seen;
});

// ---- mutation DURING an emit ----------------------------------------------------------------
// node copies the listener list for the emit in flight, so a listener added or removed while it
// runs takes effect on the NEXT emit. Code that unsubscribes itself relies on this.
attempt('remove-during-emit', () => {
  const seen = [];
  const emitter = new EventEmitter();
  const second = () => seen.push('second');
  emitter.on('x', () => { seen.push('first'); emitter.removeListener('x', second); });
  emitter.on('x', second);
  emitter.emit('x');
  emitter.emit('x');
  return seen;
});

attempt('add-during-emit', () => {
  const seen = [];
  const emitter = new EventEmitter();
  emitter.on('x', () => {
    seen.push('first');
    if (emitter.listenerCount('x') < 2) emitter.on('x', () => seen.push('added'));
  });
  emitter.emit('x');
  emitter.emit('x');
  return seen;
});

attempt('removeAll-during-emit', () => {
  const seen = [];
  const emitter = new EventEmitter();
  emitter.on('x', () => { seen.push('first'); emitter.removeAllListeners('x'); });
  emitter.on('x', () => seen.push('second'));
  emitter.emit('x');
  return seen + ' left=' + emitter.listenerCount('x');
});

// ---- the meta events ------------------------------------------------------------------------
attempt('newListener-before-add', () => {
  const seen = [];
  const emitter = new EventEmitter();
  emitter.on('newListener', (name, listener) => {
    seen.push('new:' + name + ' countNow=' + emitter.listenerCount(name) + ' fn=' + (typeof listener));
  });
  emitter.on('x', () => {});
  return seen;
});

attempt('removeListener-event', () => {
  const seen = [];
  const emitter = new EventEmitter();
  const listener = () => {};
  emitter.on('x', listener);
  emitter.on('removeListener', (name, removed) => {
    seen.push('removed:' + name + ' same=' + (removed === listener) + ' countNow=' + emitter.listenerCount(name));
  });
  emitter.removeListener('x', listener);
  return seen;
});

attempt('removeAll-emits-removeListener', () => {
  const seen = [];
  const emitter = new EventEmitter();
  emitter.on('a', () => {});
  emitter.on('b', () => {});
  emitter.on('removeListener', (name) => seen.push(name));
  emitter.removeAllListeners();
  return seen;
});

attempt('once-emits-removeListener', () => {
  const seen = [];
  const emitter = new EventEmitter();
  emitter.on('removeListener', (name) => seen.push('removed:' + name));
  emitter.once('x', () => seen.push('ran'));
  emitter.emit('x');
  return seen;
});

// ---- introspection ---------------------------------------------------------------------------
attempt('eventNames', () => {
  const emitter = new EventEmitter();
  const symbol = Symbol('sym');
  emitter.on('a', () => {});
  emitter.on(symbol, () => {});
  emitter.once('b', () => {});
  const names = emitter.eventNames();
  return names.length + ':' + names.map((n) => typeof n === 'symbol' ? 'symbol' : n).join(',');
});

attempt('eventNames-after-removal', () => {
  const emitter = new EventEmitter();
  const listener = () => {};
  emitter.on('a', listener);
  emitter.removeListener('a', listener);
  return emitter.eventNames().length + ' count=' + emitter.listenerCount('a')
    + ' listeners=' + emitter.listeners('a').length;
});

attempt('listenerCount-with-listener', () => {
  const emitter = new EventEmitter();
  const a = () => {}, b = () => {};
  emitter.on('x', a); emitter.on('x', a); emitter.on('x', b);
  return emitter.listenerCount('x') + ' a=' + emitter.listenerCount('x', a)
    + ' b=' + emitter.listenerCount('x', b);
});

attempt('listeners-is-a-copy', () => {
  const emitter = new EventEmitter();
  emitter.on('x', () => {});
  const copy = emitter.listeners('x');
  copy.push(() => {});
  return emitter.listenerCount('x') + ' copyLength=' + copy.length;
});

attempt('maxListeners', () => {
  const emitter = new EventEmitter();
  const initial = emitter.getMaxListeners();
  emitter.setMaxListeners(3);
  return initial + ' then=' + emitter.getMaxListeners()
    + ' default=' + EventEmitter.defaultMaxListeners
    + ' static=' + (typeof events.setMaxListeners) + ',' + (typeof events.getEventListeners);
});

attempt('getEventListeners', () => {
  const emitter = new EventEmitter();
  const listener = () => {};
  emitter.on('x', listener);
  const got = events.getEventListeners(emitter, 'x');
  return got.length + ' same=' + (got[0] === listener);
});

// ---- errors ------------------------------------------------------------------------------------
attempt('error-without-listener', () => {
  const emitter = new EventEmitter();
  emitter.emit('error', Object.assign(new Error('boom'), { code: 'EBOOM' }));
  return 'did not throw';
});

attempt('error-without-listener-nonerror', () => {
  const emitter = new EventEmitter();
  emitter.emit('error', 'just a string');
  return 'did not throw';
});

attempt('error-with-listener', () => {
  const emitter = new EventEmitter();
  let got = null;
  emitter.on('error', (error) => { got = error.code; });
  const returned = emitter.emit('error', Object.assign(new Error('boom'), { code: 'EBOOM' }));
  return got + ' returned=' + returned;
});

attempt('errorMonitor', () => {
  const seen = [];
  const emitter = new EventEmitter();
  emitter.on(events.errorMonitor, () => seen.push('monitor'));
  emitter.on('error', () => seen.push('handler'));
  emitter.emit('error', new Error('boom'));
  return seen;
});

attempt('errorMonitor-alone-still-throws', () => {
  const emitter = new EventEmitter();
  emitter.on(events.errorMonitor, () => {});
  emitter.emit('error', Object.assign(new Error('boom'), { code: 'EMON' }));
  return 'did not throw';
});

// ---- the leak warning, which is the only thing maxListeners actually does ------------------
attempt('static-setMaxListeners', () => {
  const emitter = new EventEmitter();
  events.setMaxListeners(4, emitter);
  return emitter.getMaxListeners();
});

// A prototype mixed into a plain object without ever calling the constructor — how express
// builds its app — has no _events until something asks for one.
attempt('mixin-without-constructor', () => {
  const target = Object.assign(function () {}, EventEmitter.prototype);
  let got = null;
  target.on('x', (value) => { got = value; });
  target.emit('x', 'through the mixin');
  return got + ' names=' + target.eventNames().join(',');
});

attempt('symbol-events', () => {
  const emitter = new EventEmitter();
  const symbol = Symbol.for('probe.symbol');
  let got = null;
  emitter.on(symbol, (value) => { got = value; });
  emitter.emit(symbol, 'symbol payload');
  return got + ' count=' + emitter.listenerCount(symbol)
    + ' inNames=' + emitter.eventNames().includes(symbol);
});

// ---- the promise and iterator helpers ------------------------------------------------------------
async function asyncScenarios() {
  const namedThen = async (name, fn) => {
    try { line(name, show(await fn())); }
    catch (error) { line(name, 'REJECTED ' + (error && (error.code || error.message))); }
  };

  await namedThen('events.once', async () => {
    const emitter = new EventEmitter();
    setTimeout(() => emitter.emit('x', 'value', 'second'), 5);
    return await events.once(emitter, 'x');
  });

  await namedThen('events.once-rejects-on-error', async () => {
    const emitter = new EventEmitter();
    setTimeout(() => emitter.emit('error', Object.assign(new Error('nope'), { code: 'ENOPE' })), 5);
    return await events.once(emitter, 'x');
  });

  await namedThen('events.once-leaves-nothing', async () => {
    const emitter = new EventEmitter();
    setTimeout(() => emitter.emit('x'), 5);
    await events.once(emitter, 'x');
    return emitter.listenerCount('x') + ',' + emitter.listenerCount('error');
  });

  await namedThen('events.once-abort', async () => {
    const emitter = new EventEmitter();
    const controller = new AbortController();
    setTimeout(() => controller.abort(), 5);
    return await events.once(emitter, 'x', { signal: controller.signal });
  });

  await namedThen('events.on-iterator', async () => {
    const emitter = new EventEmitter();
    let n = 0;
    const timer = setInterval(() => { emitter.emit('tick', ++n); }, 3);
    const got = [];
    for await (const [value] of events.on(emitter, 'tick')) {
      got.push(value);
      if (got.length === 3) break;
    }
    clearInterval(timer);
    return got;
  });

  await namedThen('captureRejections', async () => {
    const emitter = new EventEmitter({ captureRejections: true });
    let captured = null;
    emitter.on('error', (error) => { captured = error.code; });
    emitter.on('x', async () => { throw Object.assign(new Error('async'), { code: 'EASYNC' }); });
    emitter.emit('x');
    await new Promise((resolve) => setTimeout(resolve, 20));
    return 'captured=' + captured + ' flag=' + (typeof emitter[Symbol.for('nodejs.rejection')]);
  });

  // The warning is delivered on the loop, so observing it means waiting for it — which is
  // also the only way to prove the limit does anything at all.
  await namedThen('maxListeners-warning', async () => {
    const seen = [];
    const onWarning = (warning) => seen.push(warning.name + ' count=' + warning.count + ' type=' + warning.type);
    process.on('warning', onWarning);
    const emitter = new EventEmitter();
    emitter.setMaxListeners(2);
    for (let i = 0; i < 4; i += 1) emitter.on('x', () => {});
    await new Promise((resolve) => setTimeout(resolve, 20));
    process.removeListener('warning', onWarning);
    return seen.length + ':' + seen.join(';');
  });

  await namedThen('maxListeners-zero-disables', async () => {
    const seen = [];
    const onWarning = (warning) => seen.push(warning.name);
    process.on('warning', onWarning);
    const emitter = new EventEmitter();
    emitter.setMaxListeners(0);
    for (let i = 0; i < 30; i += 1) emitter.on('x', () => {});
    await new Promise((resolve) => setTimeout(resolve, 20));
    process.removeListener('warning', onWarning);
    return seen.length + ' count=' + emitter.listenerCount('x');
  });

  await namedThen('captureRejection-symbol-handler', async () => {
    const emitter = new EventEmitter({ captureRejections: true });
    let handled = null;
    emitter[Symbol.for('nodejs.rejection')] = function (error, name) { handled = name + ':' + error.code; };
    emitter.on('x', async () => { throw Object.assign(new Error('custom'), { code: 'ECUSTOM' }); });
    emitter.emit('x', 'arg');
    await new Promise((resolve) => setTimeout(resolve, 20));
    return handled;
  });

  await namedThen('no-captureRejections', async () => {
    const emitter = new EventEmitter();
    let captured = 'none';
    emitter.on('error', (error) => { captured = error.code; });
    emitter.on('x', async () => { throw Object.assign(new Error('async'), { code: 'ELOOSE' }); });
    emitter.emit('x');
    await new Promise((resolve) => setTimeout(resolve, 20));
    return 'captured=' + captured;
  });
}

asyncScenarios().then(() => line('done', 'yes'),
                      (error) => line('done', 'FAILED ' + (error && error.message)));
