// jest through its programmatic API, each test file in a real `vm` context.
//
// Run TWICE with the cache ENABLED, because the second run reads back the haste map the first
// wrote — which is what caught v8.serialize being JSON.stringify. A haste map is mostly Maps
// and Sets, JSON turns those into {} without complaining, and jest hung on a cache it believed
// was warm. Running once, or with cache: false, would not have exercised that path.
//
// The project lives in ./project so the harness's own files — a multi-megabyte binary among
// them — are not in the tree jest crawls; they were once, and jest spent forever walking them.
const jest = require('./project/node_modules/jest');
const opts = { _: [], $0: 'jest', silent: true, ci: true, runInBand: true, maxWorkers: 1 };
const root = process.cwd() + '/project';
const report = (label, results) => {
  const lines = [];
  for (const suite of results.testResults) {
    for (const t of suite.testResults) lines.push(label + ' ' + t.status + ' ' + t.fullName);
  }
  lines.push(label + ' total=' + results.numTotalTests + ' passed=' + results.numPassedTests +
             ' failed=' + results.numFailedTests + ' skipped=' + results.numPendingTests);
  return lines.join('\n');
};
jest.runCLI(opts, [root])
  .then(a => { console.log(report('cold', a.results)); return jest.runCLI(opts, [root]); })
  .then(b => console.log(report('warm', b.results)),
        e => console.log('THREW ' + String(e && e.message).slice(0, 200)));
