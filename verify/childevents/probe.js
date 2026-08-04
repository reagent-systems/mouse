// A child's event SEQUENCE is a contract: 'spawn' when it is running, 'exit' when it is gone,
// 'close' when its stdio has drained — in that order. jest-haste-map waits on 'exit'; other
// code waits on 'spawn'. A missing or reordered event is a hang, not a cosmetic difference.
const { spawn } = require('child_process');
const seen = [];
const child = spawn(process.execPath, ['-e', 'console.log("hi")']);
for (const name of ['spawn', 'exit', 'close', 'error']) child.on(name, () => seen.push(name));
child.stdout.on('data', () => seen.push('data'));
child.on('close', () => {
  // 'data' can interleave; the ORDER of the three lifecycle events is what is asserted.
  console.log('lifecycle: ' + seen.filter(e => e !== 'data').join(' '));
  console.log('saw data: ' + seen.includes('data'));
  console.log('exitCode: ' + child.exitCode);
});
