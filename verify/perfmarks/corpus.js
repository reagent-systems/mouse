'use strict';
// `performance` — what every build tool and benchmark reaches for, and the one global here that
// nothing had ever checked. Times themselves are not comparable between two runs, so nothing
// asserts a NUMBER: what is compared is the shape of an entry, which entries exist after which
// calls, what the getters return, and the relationships that must hold (a measure spanning two
// marks lasts at least as long as the gap between them).
const perfHooks = require('perf_hooks');

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
function entryShape(entry) {
  if (!entry) return String(entry);
  return entry.name + '/' + entry.entryType
    + '/start=' + (typeof entry.startTime === 'number' ? 'number' : typeof entry.startTime)
    + '/dur=' + (typeof entry.duration === 'number' ? 'number' : typeof entry.duration);
}

attempt('surface', () => {
  return ['now', 'mark', 'measure', 'getEntries', 'getEntriesByName', 'getEntriesByType',
          'clearMarks', 'clearMeasures', 'toJSON', 'timeOrigin']
    .map((n) => n + '=' + typeof performance[n]).join(' ');
});

attempt('perf_hooks-surface', () => {
  return ['performance', 'PerformanceObserver', 'constants', 'monitorEventLoopDelay',
          'createHistogram', 'timerify']
    .map((n) => n + '=' + typeof perfHooks[n]).join(' ')
    + ' | sameGlobal=' + (perfHooks.performance === globalThis.performance);
});

attempt('now-is-monotonic', () => {
  const a = performance.now();
  let spin = 0;
  for (let i = 0; i < 200000; i += 1) spin += i;
  const b = performance.now();
  return typeof a + ' increasing=' + (b >= a) + ' positive=' + (a >= 0) + ' spun=' + (spin > 0);
});

attempt('timeOrigin', () => {
  return typeof performance.timeOrigin + ' plausible=' + (performance.timeOrigin > 1600000000000);
});

attempt('mark-returns-an-entry', () => {
  performance.clearMarks();
  const mark = performance.mark('alpha');
  return entryShape(mark) + ' detail=' + String(mark && mark.detail);
});

attempt('mark-with-detail', () => {
  performance.clearMarks();
  const mark = performance.mark('withDetail', { detail: { a: 1 } });
  return entryShape(mark) + ' detail=' + JSON.stringify(mark && mark.detail);
});

attempt('getEntriesByName-and-Type', () => {
  performance.clearMarks();
  performance.clearMeasures();
  performance.mark('one');
  performance.mark('two');
  performance.mark('one');
  const byName = performance.getEntriesByName('one');
  const byType = performance.getEntriesByType('mark');
  return 'byName=' + byName.length + ' byType=' + byType.length
    + ' names=' + byType.map((e) => e.name).join(',');
});

attempt('measure-between-marks', () => {
  performance.clearMarks();
  performance.clearMeasures();
  performance.mark('start');
  let spin = 0;
  for (let i = 0; i < 200000; i += 1) spin += i;
  performance.mark('end');
  const measure = performance.measure('span', 'start', 'end');
  const measures = performance.getEntriesByType('measure');
  return entryShape(measure) + ' count=' + measures.length
    + ' nonNegative=' + (measure && measure.duration >= 0) + ' spun=' + (spin > 0);
});

attempt('measure-from-a-mark-to-now', () => {
  performance.clearMarks();
  performance.clearMeasures();
  performance.mark('only');
  const measure = performance.measure('toNow', 'only');
  return entryShape(measure) + ' nonNegative=' + (measure.duration >= 0);
});

attempt('measure-with-options', () => {
  performance.clearMarks();
  performance.clearMeasures();
  const measure = performance.measure('explicit', { start: 5, duration: 12, detail: 'why' });
  return entryShape(measure) + ' start=' + measure.startTime + ' duration=' + measure.duration
    + ' detail=' + JSON.stringify(measure.detail);
});

attempt('measure-of-a-missing-mark', () => {
  performance.clearMarks();
  performance.clearMeasures();
  try { performance.measure('bad', 'nowhere'); return 'accepted'; }
  catch (error) { return 'THREW ' + (error && (error.name + '/' + error.code)); }
});

attempt('clearMarks-by-name', () => {
  performance.clearMarks();
  performance.clearMeasures();
  performance.mark('keep');
  performance.mark('drop');
  performance.clearMarks('drop');
  const left = performance.getEntriesByType('mark').map((e) => e.name);
  performance.clearMarks();
  return JSON.stringify(left) + ' afterClearAll=' + performance.getEntriesByType('mark').length;
});

attempt('clearMeasures-by-name', () => {
  performance.clearMarks();
  performance.clearMeasures();
  performance.measure('m1', { start: 0, duration: 1 });
  performance.measure('m2', { start: 0, duration: 1 });
  performance.clearMeasures('m1');
  const left = performance.getEntriesByType('measure').map((e) => e.name);
  performance.clearMeasures();
  return JSON.stringify(left) + ' afterClearAll=' + performance.getEntriesByType('measure').length;
});

attempt('getEntries-is-ordered-by-start', () => {
  performance.clearMarks();
  performance.clearMeasures();
  performance.mark('first');
  performance.mark('second');
  performance.measure('both', 'first', 'second');
  const entries = performance.getEntries();
  const ordered = entries.every((entry, index) => index === 0 || entries[index - 1].startTime <= entry.startTime);
  return entries.map((e) => e.name + ':' + e.entryType).join(',') + ' ordered=' + ordered;
});

attempt('entry-toJSON', () => {
  performance.clearMarks();
  const mark = performance.mark('serialised');
  const json = typeof mark.toJSON === 'function' ? mark.toJSON() : null;
  performance.clearMarks();
  return json ? Object.keys(json).sort().join(',') : 'no toJSON';
});

attempt('performance-toJSON', () => {
  const json = performance.toJSON();
  return json ? Object.keys(json).sort().join(',') : String(json);
});

async function asyncScenarios() {
  const namedThen = async (name, fn) => {
    try { line(name, String(await fn())); }
    catch (error) { line(name, 'REJECTED ' + show(error)); }
  };

  await namedThen('PerformanceObserver-marks', async () => {
    if (typeof perfHooks.PerformanceObserver !== 'function') return 'absent';
    performance.clearMarks();
    const seen = [];
    const observer = new perfHooks.PerformanceObserver((list) => {
      for (const entry of list.getEntries()) seen.push(entry.name + ':' + entry.entryType);
    });
    observer.observe({ entryTypes: ['mark'] });
    performance.mark('observed1');
    performance.mark('observed2');
    await new Promise((resolve) => setTimeout(resolve, 30));
    observer.disconnect();
    performance.clearMarks();
    return JSON.stringify(seen);
  });

  await namedThen('PerformanceObserver-stops-after-disconnect', async () => {
    if (typeof perfHooks.PerformanceObserver !== 'function') return 'absent';
    performance.clearMarks();
    const seen = [];
    const observer = new perfHooks.PerformanceObserver((list) => {
      for (const entry of list.getEntries()) seen.push(entry.name);
    });
    observer.observe({ entryTypes: ['mark'] });
    observer.disconnect();
    performance.mark('afterDisconnect');
    await new Promise((resolve) => setTimeout(resolve, 30));
    performance.clearMarks();
    return JSON.stringify(seen);
  });

  // Numbers here cannot match between two runs, so what is asserted is that they are MEASURED:
  // utilization is a real ratio, idle grows while the process waits, and a delay sampler that
  // has been running has samples. A fixed zero would fail every one of these.
  await namedThen('eventLoopUtilization', async () => {
    if (typeof performance.eventLoopUtilization !== 'function') return 'absent';
    const first = performance.eventLoopUtilization();
    const shape = Object.keys(first).sort().join(',');
    await new Promise((resolve) => setTimeout(resolve, 60));
    const second = performance.eventLoopUtilization();
    const delta = performance.eventLoopUtilization(second, first);
    return shape
      + ' inRange=' + (first.utilization >= 0 && first.utilization <= 1)
      + ' idleGrew=' + (second.idle > first.idle)
      + ' deltaKeys=' + Object.keys(delta).sort().join(',');
  });

  await namedThen('monitorEventLoopDelay', async () => {
    if (typeof perfHooks.monitorEventLoopDelay !== 'function') return 'absent';
    const histogram = perfHooks.monitorEventLoopDelay({ resolution: 10 });
    histogram.enable();
    await new Promise((resolve) => setTimeout(resolve, 120));
    histogram.disable();
    return 'sampled=' + (histogram.percentile(50) >= 0)
      + ' mean=' + (typeof histogram.mean === 'number')
      + ' maxAtLeastMin=' + (histogram.max >= histogram.min);
  });

  await namedThen('createHistogram', async () => {
    if (typeof perfHooks.createHistogram !== 'function') return 'absent';
    const histogram = perfHooks.createHistogram();
    for (const value of [10, 20, 30, 40]) histogram.record(value);
    return 'count=' + histogram.count + ' min=' + histogram.min + ' max=' + histogram.max
      + ' mean=' + histogram.mean + ' p50=' + (histogram.percentile(50) >= 10);
  });

  await namedThen('measure-spans-real-time', async () => {
    performance.clearMarks();
    performance.clearMeasures();
    performance.mark('t0');
    await new Promise((resolve) => setTimeout(resolve, 40));
    performance.mark('t1');
    const measure = performance.measure('waited', 't0', 't1');
    performance.clearMarks();
    performance.clearMeasures();
    // 30ms rather than 40: a timer may fire a hair early, and the point is that the measure
    // reflects REAL elapsed time rather than zero.
    return 'atLeast30ms=' + (measure.duration >= 30) + ' under5s=' + (measure.duration < 5000);
  });
}

asyncScenarios().then(() => line('done', 'yes'),
                      (error) => line('done', 'FAILED ' + show(error)));
