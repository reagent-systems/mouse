// mocha through its programmatic API, which is what a runner integration uses. Durations vary
// run to run, so the reporter output is not comparable — the RESULTS are: which tests passed,
// failed, were pending, in what order, with which error messages, and the process exit code.
const Mocha = require('mocha');
const mocha = new Mocha({ reporter: 'min', timeout: 2000 });
mocha.addFile(require('path').resolve('test/suite.js'));
const lines = [];
const runner = mocha.run(function (failures) {
  lines.push('failures: ' + failures);
  console.log(lines.join('\n'));
  process.exitCode = failures ? 1 : 0;
});
runner.on('pass', t => lines.push('pass    ' + t.fullTitle()));
runner.on('pending', t => lines.push('pending ' + t.fullTitle()));
runner.on('fail', (t, e) => lines.push('fail    ' + t.fullTitle() + ' | ' + e.message.split('\n')[0].slice(0, 80)));
