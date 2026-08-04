// Every consumer node defines in terms of the structured clone algorithm. Each was
// JSON.parse(JSON.stringify(...)), which loses all of this without saying so.
const { Worker, setEnvironmentData, getEnvironmentData } = require('worker_threads');
const out = [];
const rich = { m: new Map([['k', 1]]), s: new Set([2]), d: new Date(7), u: undefined, big: 9n, arr: [1, [2]] };
const c = structuredClone(rich);
out.push('structuredClone map: ' + (c.m instanceof Map && c.m.get('k') === 1));
out.push('structuredClone set: ' + (c.s instanceof Set && c.s.has(2)));
out.push('structuredClone date: ' + (c.d instanceof Date && c.d.getTime() === 7));
out.push('structuredClone undefined: ' + ('u' in c && c.u === undefined));
out.push('structuredClone bigint: ' + (c.big === 9n));
out.push('structuredClone deep: ' + (c.arr[1][0] === 2));
const cyc = { n: 1 }; cyc.self = cyc;
out.push('structuredClone cycle: ' + (structuredClone(cyc).self.n === 1));
out.push('structuredClone is a copy: ' + (structuredClone(rich).m !== rich.m));
setEnvironmentData('cfg', new Map([['mode', 'test']]));
const back = getEnvironmentData('cfg');
out.push('environmentData map: ' + (back instanceof Map && back.get('mode') === 'test'));
out.push('environmentData is a copy: ' + (back !== undefined));

// An eval worker, so this tests the CLONE across the boundary and not module resolution.
const w = new Worker(`
  const { workerData, parentPort, getEnvironmentData } = require('worker_threads');
  parentPort.postMessage({
    wdMap: workerData.m instanceof Map && workerData.m.get('w') === 5,
    wdDate: workerData.d instanceof Date && workerData.d.getTime() === 3,
    wdSet: workerData.s instanceof Set && workerData.s.has('q'),
    env: (() => { const e = getEnvironmentData('cfg'); return e instanceof Map && e.get('mode') === 'test'; })(),
    echo: new Map([['e', 8]]),
  });
`, { eval: true, workerData: { m: new Map([['w', 5]]), d: new Date(3), s: new Set(['q']) } });
w.on('message', (msg) => {
  out.push('workerData map: ' + msg.wdMap);
  out.push('workerData date: ' + msg.wdDate);
  out.push('workerData set: ' + msg.wdSet);
  out.push('env reaches worker: ' + msg.env);
  out.push('postMessage map back: ' + (msg.echo instanceof Map && msg.echo.get('e') === 8));
  console.log(out.join('\n'));
  w.terminate();
});
