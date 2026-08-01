// Error paths across the remaining subsystems. Each is a failure a real program hits: a missing
// binary, a worker that throws, corrupt compressed data, a watch on a path that is not there.
const { spawn } = require('child_process'), zlib = require('zlib'), fs = require('fs');
const { Worker } = require('worker_threads');
const out = [];
const finish = () => { console.log(out.sort().join('\n')); process.exit(0); };

// 1. spawn a binary that does not exist
const child = spawn('definitely-not-a-real-binary-xyz', []);
child.on('error', e => { out.push('spawn error code=' + e.code); step2(); });
child.on('exit', c => { out.push('spawn exit code=' + c); step2(); });
setTimeout(() => { if (!out.some(l => l.startsWith('spawn'))) { out.push('spawn NO SIGNAL'); step2(); } }, 800);

let stepped = false;
function step2() {
  if (stepped) return; stepped = true;
  // 2. corrupt gzip input
  try { zlib.gunzipSync(Buffer.from('not gzip at all')); out.push('gunzip corrupt: NO THROW'); }
  catch (e) { out.push('gunzip corrupt code=' + (e.code || e.message.slice(0, 20))); }
  zlib.gunzip(Buffer.from('still not gzip'), (err) => {
    out.push('gunzip async err=' + (err ? (err.code || 'yes') : 'none'));
    step3();
  });
}
function step3() {
  // 3. a worker that throws
  const w = new Worker("throw new Error('worker blew up');", { eval: true });
  let settled = false;
  // The parent must learn WHY, not just that: node emits 'error' carrying the exception.
  w.on('error', e => { if (!settled) { settled = true; out.push('worker error=' + e.name + ':' + e.message); step4(); } });
  w.on('exit', c => { if (!settled) { settled = true; out.push('worker exit only=' + c); step4(); } });
  setTimeout(() => { if (!settled) { settled = true; out.push('worker NO SIGNAL'); step4(); } }, 1500);
}
function step4() {
  // 4. watch a path that is not there
  try { const w = fs.watch('/no/such/path/at/all', () => {}); out.push('watch missing: NO THROW'); w.close(); }
  catch (e) { out.push('watch missing code=' + e.code); }
  finish();
}
