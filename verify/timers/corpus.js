'use strict';
// Timers: the other substrate everything async here is scheduled through. What is under test is
// not "does the callback run" but the rules a caller depends on — which phase runs first, what a
// handle is and what can be done with it, how a delay is coerced, and what the promise forms
// resolve with. Nothing nondeterministic is asserted: a bare setTimeout(0) racing setImmediate
// is genuinely unordered in node, so every ordering here is one node actually guarantees.
const timers = require('timers');
const timersPromises = require('timers/promises');

const done = [];
function line(name, value) { console.log(name + '\t' + value); }
function attempt(name, fn) {
  try { line(name, String(fn())); }
  catch (error) { line(name, 'THREW ' + (error && (error.code || error.message))); }
}
function later(ms) { return new Promise((resolve) => setTimeout(resolve, ms)); }

// ---- what a handle IS -----------------------------------------------------------------------
attempt('timeout-handle-shape', () => {
  const handle = setTimeout(() => {}, 1000);
  const shape = [typeof handle, typeof handle.ref, typeof handle.unref, typeof handle.hasRef,
                 typeof handle.refresh, typeof handle.close,
                 typeof handle[Symbol.toPrimitive]].join(',');
  clearTimeout(handle);
  return shape;
});

attempt('timeout-primitive-is-a-number', () => {
  const handle = setTimeout(() => {}, 1000);
  const asNumber = Number(handle);
  clearTimeout(handle);
  return typeof asNumber + ' finite=' + Number.isFinite(asNumber);
});

attempt('interval-handle-shape', () => {
  const handle = setInterval(() => {}, 1000);
  const shape = typeof handle + ',' + typeof handle.unref + ',' + typeof handle.refresh;
  clearInterval(handle);
  return shape;
});

attempt('immediate-handle-shape', () => {
  const handle = setImmediate(() => {});
  const shape = typeof handle + ',' + typeof handle.ref + ',' + typeof handle.hasRef;
  clearImmediate(handle);
  return shape;
});

attempt('ref-unref-hasRef', () => {
  const handle = setTimeout(() => {}, 1000);
  const initial = handle.hasRef();
  handle.unref();
  const afterUnref = handle.hasRef();
  handle.ref();
  const afterRef = handle.hasRef();
  clearTimeout(handle);
  return initial + ',' + afterUnref + ',' + afterRef + ' chain=' + (handle.unref() === handle);
});

// The values a caller actually passes: an uninitialised variable, a cleared id, a computed NaN.
// A string and a plain object are left out, and not because they are exotic — node's
// clearImmediate throws on the first from its own internals ("Cannot create property
// '_destroyed' on string") and, on the second, quietly BREAKS ITS IMMEDIATE QUEUE for the rest
// of the process: every later setImmediate is scheduled and never runs. Neither is documented
// behaviour, and asserting either would be copying an implementation accident.
attempt('clear-tolerates-anything', () => {
  const results = [];
  for (const value of [undefined, null, 0, NaN]) {
    try { clearTimeout(value); clearInterval(value); clearImmediate(value); results.push('ok'); }
    catch (error) { results.push('THREW ' + (error && error.code)); }
  }
  return results.join(',');
});

attempt('bad-callback', () => {
  try { setTimeout('not a function', 1); return 'accepted'; }
  catch (error) { return 'THREW ' + (error && error.code); }
});

// ---- delay coercion -------------------------------------------------------------------------
// Every one of these is 1ms in node. A caller passing a negative or NaN delay usually computed
// it, and a timer that never fires is the failure mode.
async function delayCoercion() {
  const order = [];
  const stamp = (label) => order.push(label);
  await new Promise((resolve) => {
    setTimeout(() => { stamp('negative'); }, -5);
    setTimeout(() => { stamp('nan'); }, NaN);
    setTimeout(() => { stamp('string'); }, '3');
    setTimeout(() => { stamp('zero'); }, 0);
    setTimeout(() => { stamp('undefined'); }, undefined);
    setTimeout(resolve, 40);
  });
  line('delay-coercion', order.join(','));
}

async function overflowWarning() {
  const seen = [];
  const onWarning = (warning) => seen.push(warning.name);
  process.on('warning', onWarning);
  const handle = setTimeout(() => {}, 2 ** 32);
  await later(20);
  clearTimeout(handle);
  process.removeListener('warning', onWarning);
  line('overflow-warning', seen.join(',') || 'none');
}

// ---- phase ordering, only where node guarantees it -------------------------------------------
async function phaseOrder() {
  const order = [];
  await new Promise((resolve) => {
    setTimeout(() => order.push('timeout'), 0);
    Promise.resolve().then(() => order.push('promise'));
    process.nextTick(() => order.push('tick'));
    queueMicrotask(() => order.push('microtask'));
    setTimeout(resolve, 30);
  });
  line('phase-order', order.join(','));
}

async function nestedTicks() {
  const order = [];
  await new Promise((resolve) => {
    process.nextTick(() => {
      order.push('tick1');
      process.nextTick(() => order.push('tick2'));
      Promise.resolve().then(() => order.push('promise-inside-tick'));
    });
    Promise.resolve().then(() => order.push('promise1'));
    setTimeout(resolve, 20);
  });
  line('nested-ticks', order.join(','));
}

async function immediateVsTimeoutInsideIO() {
  // Inside an I/O callback the order IS defined: immediates run before the next timer phase.
  const order = [];
  await new Promise((resolve) => {
    require('fs').readFile(__filename, () => {
      setTimeout(() => order.push('timeout'), 0);
      setImmediate(() => order.push('immediate'));
      setTimeout(resolve, 40);
    });
  });
  line('immediate-before-timeout-in-io', order.join(','));
}

async function sameDelayIsInsertionOrder() {
  const order = [];
  await new Promise((resolve) => {
    setTimeout(() => order.push('a'), 5);
    setTimeout(() => order.push('b'), 5);
    setTimeout(() => order.push('c'), 5);
    setTimeout(resolve, 30);
  });
  line('same-delay-insertion-order', order.join(','));
}

async function nestedTimerOrder() {
  const order = [];
  await new Promise((resolve) => {
    setTimeout(() => {
      order.push('outer');
      setTimeout(() => order.push('inner'), 0);
    }, 0);
    setTimeout(() => order.push('sibling'), 0);
    setTimeout(resolve, 40);
  });
  line('nested-timer-order', order.join(','));
}

// ---- arguments and clearing -------------------------------------------------------------------
async function extraArguments() {
  const got = await new Promise((resolve) => {
    setTimeout((a, b, c) => resolve([a, b, c].join('|')), 1, 'x', 2, true);
  });
  line('extra-arguments', got);
  const fromInterval = await new Promise((resolve) => {
    const handle = setInterval((value) => { clearInterval(handle); resolve(value); }, 1, 'interval arg');
  });
  line('interval-arguments', fromInterval);
}

async function clearBeforeFiring() {
  const order = [];
  await new Promise((resolve) => {
    const handle = setTimeout(() => order.push('should not run'), 5);
    clearTimeout(handle);
    setTimeout(() => { order.push('ran'); resolve(); }, 25);
  });
  line('clear-before-firing', order.join(',') || 'nothing');
}

async function clearByPrimitive() {
  const order = [];
  await new Promise((resolve) => {
    const handle = setTimeout(() => order.push('should not run'), 5);
    clearTimeout(Number(handle));
    setTimeout(resolve, 25);
  });
  line('clear-by-primitive-id', order.join(',') || 'nothing');
}

async function refreshRestarts() {
  const order = [];
  await new Promise((resolve) => {
    const start = Date.now();
    const handle = setTimeout(() => order.push('fired after ' + (Date.now() - start >= 25 ? 'refresh' : 'original')), 20);
    setTimeout(() => { handle.refresh(); }, 10);
    setTimeout(resolve, 60);
  });
  line('refresh-restarts', order.join(',') || 'never fired');
}

async function intervalRepeats() {
  let count = 0;
  await new Promise((resolve) => {
    const handle = setInterval(() => {
      count += 1;
      if (count === 3) { clearInterval(handle); resolve(); }
    }, 5);
  });
  line('interval-repeats', count);
}

async function clearIntervalFromInside() {
  let count = 0;
  await new Promise((resolve) => {
    const handle = setInterval(() => { count += 1; clearInterval(handle); }, 5);
    setTimeout(resolve, 40);
  });
  line('clear-interval-from-inside', count);
}

async function immediateOrder() {
  const order = [];
  await new Promise((resolve) => {
    setImmediate(() => order.push('first'));
    setImmediate(() => order.push('second'));
    setImmediate(() => { order.push('third'); resolve(); });
  });
  line('immediate-order', order.join(','));
}

async function immediateArguments() {
  const got = await new Promise((resolve) => setImmediate((a, b) => resolve(a + '|' + b), 'one', 'two'));
  line('immediate-arguments', got);
}

// ---- the promise forms --------------------------------------------------------------------------
async function promiseForms() {
  line('promises-setTimeout-value', await timersPromises.setTimeout(5, 'resolved value'));
  line('promises-setTimeout-default', String(await timersPromises.setTimeout(5)));
  line('promises-setImmediate', await timersPromises.setImmediate('immediate value'));

  try {
    const controller = new AbortController();
    setTimeout(() => controller.abort(), 5);
    await timersPromises.setTimeout(200, 'never', { signal: controller.signal });
    line('promises-abort', 'resolved anyway');
  } catch (error) {
    line('promises-abort', 'REJECTED ' + (error && error.code) + ' name=' + (error && error.name));
  }

  try {
    const controller = new AbortController();
    controller.abort();
    await timersPromises.setTimeout(5, 'never', { signal: controller.signal });
    line('promises-already-aborted', 'resolved anyway');
  } catch (error) {
    line('promises-already-aborted', 'REJECTED ' + (error && error.code));
  }

  const ticks = [];
  for await (const value of timersPromises.setInterval(4, 'tick')) {
    ticks.push(value);
    if (ticks.length === 3) break;
  }
  line('promises-setInterval', ticks.join(','));

  line('promises-surface', ['setTimeout', 'setImmediate', 'setInterval', 'scheduler']
    .map((name) => name + '=' + typeof timersPromises[name]).join(' '));
}

// ---- the timers module's own surface ----------------------------------------------------------
attempt('timers-module-surface', () => {
  return ['setTimeout', 'setInterval', 'setImmediate', 'clearTimeout', 'clearInterval',
          'clearImmediate', 'promises'].map((name) => name + '=' + typeof timers[name]).join(' ');
});

attempt('globals-match-module', () => {
  return (timers.setTimeout === setTimeout) + ',' + (timers.clearTimeout === clearTimeout);
});

(async () => {
  await delayCoercion();
  await overflowWarning();
  await phaseOrder();
  await nestedTicks();
  await immediateVsTimeoutInsideIO();
  await sameDelayIsInsertionOrder();
  await nestedTimerOrder();
  await extraArguments();
  await clearBeforeFiring();
  await clearByPrimitive();
  await refreshRestarts();
  await intervalRepeats();
  await clearIntervalFromInside();
  await immediateOrder();
  await immediateArguments();
  await promiseForms();
  line('done', 'yes');
})().catch((error) => line('done', 'FAILED ' + (error && (error.stack || error.message))));
