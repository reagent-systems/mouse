const cp = require('child_process');
const which = process.argv[2];
if (which === 'input') {
  const r = cp.spawnSync('node', ['-e', 'process.stdin.on("data",d=>process.stdout.write("got:"+d))'],
                         { input: 'fed', encoding: 'utf8' });
  console.log('input result: ' + JSON.stringify(r.stdout));
} else if (which === 'timeout') {
  const t = Date.now();
  const r = cp.spawnSync('node', ['-e', 'setTimeout(()=>{},5000)'], { timeout: 300, encoding: 'utf8' });
  console.log('timeout after ' + (Date.now() - t) + 'ms signal=' + r.signal);
} else if (which === 'encoding') {
  const r = cp.spawnSync('node', ['-e', 'process.stdout.write("text")'], { encoding: 'utf8' });
  console.log('encoding type: ' + typeof r.stdout);
}
