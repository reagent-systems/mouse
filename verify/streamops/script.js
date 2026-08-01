const { Readable } = require('stream');
const src = () => Readable.from([1, 2, 3, 4, 5]);
const out = [];
(async () => {
  out.push('toArray: ' + JSON.stringify(await src().toArray()));
  out.push('map: ' + JSON.stringify(await src().map(x => x * 2).toArray()));
  out.push('filter: ' + JSON.stringify(await src().filter(x => x % 2 === 1).toArray()));
  out.push('take: ' + JSON.stringify(await src().take(2).toArray()));
  out.push('take 0: ' + JSON.stringify(await src().take(0).toArray()));
  out.push('take beyond: ' + JSON.stringify(await src().take(99).toArray()));
  out.push('drop: ' + JSON.stringify(await src().drop(3).toArray()));
  out.push('drop all: ' + JSON.stringify(await src().drop(99).toArray()));
  out.push('flatMap: ' + JSON.stringify(await src().flatMap(x => [x, -x]).toArray()));
  out.push('reduce: ' + await src().reduce((a, b) => a + b));
  out.push('reduce seeded: ' + await src().reduce((a, b) => a + b, 100));
  out.push('some true: ' + await src().some(x => x > 4));
  out.push('some false: ' + await src().some(x => x > 9));
  out.push('every true: ' + await src().every(x => x > 0));
  out.push('every false: ' + await src().every(x => x > 3));
  out.push('find: ' + await src().find(x => x > 3));
  out.push('find missing: ' + await src().find(x => x > 9));
  const seen = [];
  await src().forEach(x => { seen.push(x); });
  out.push('forEach: ' + JSON.stringify(seen));
  // Empty-stream edge cases, where every/some invert.
  out.push('empty every: ' + await Readable.from([]).every(x => false));
  out.push('empty some: ' + await Readable.from([]).some(x => true));
  out.push('empty reduce seeded: ' + await Readable.from([]).reduce((a, b) => a + b, 7));
  // An async mapper must be awaited, not treated as a value.
  out.push('async map: ' + JSON.stringify(await src().map(async x => x * 3).toArray()));
  // Chained, which is the point of having them.
  out.push('chained: ' + JSON.stringify(await src().map(x => x * 10).filter(x => x > 20).take(2).toArray()));
  // iterator() gives an async iterator over the same data.
  const it = src().iterator();
  const first = await it.next();
  out.push('iterator: ' + JSON.stringify(first.value) + ' done=' + first.done);
  // The returned things are streams, not arrays.
  out.push('map returns a stream: ' + (typeof src().map(x => x).pipe === 'function'));
  console.log(out.join('\n'));
})().catch(error => { console.log('THREW ' + error.message); });
