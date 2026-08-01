// Options detector, second batch. Every async check has a FALLBACK timer: an ignored option must
// report itself, never hang the sweep. (The first version had no fallback on the abort case and
// hung for ten minutes — which was the finding, arriving in the least useful possible way.)
const cp = require('child_process');
const http = require('http');
const readline = require('readline');
const { Readable } = require('stream');
const out = [];
const say = (l, v) => out.push(l + ': ' + v);
const check = (l, fn) => { try { say(l, fn()); } catch (e) { say(l, 'THREW ' + String(e.message).slice(0, 50)); } };
const race = (label, build) => new Promise(resolve => {
  let settled = false;
  const finish = value => { if (!settled) { settled = true; say(label, value); resolve(); } };
  setTimeout(() => finish('NO EFFECT (fell through)'), 1200);
  build(finish);
});

check('spawnSync encoding gives string', () => {
  const r = cp.spawnSync('node', ['-e', 'process.stdout.write("text")'], { encoding: 'utf8' });
  return typeof r.stdout === 'string';
});

(async () => {
  const server = http.createServer((req, res) => { if (req.url !== '/slow') res.end('quick'); });
  await new Promise(resolve => server.listen(0, resolve));
  const port = server.address().port;

  // An AbortSignal must abort the request. Ignored, this is an unbreakable hang.
  await race('http signal aborts', finish => {
    const controller = new AbortController();
    const request = http.get({ port, path: '/slow', signal: controller.signal }, () => finish('answered'));
    request.on('error', e => finish(e.name === 'AbortError' || e.code === 'ABORT_ERR' ? 'aborted' : 'error:' + e.code));
    setTimeout(() => controller.abort(), 100);
  });
  // The timeout option must emit 'timeout'.
  await race('http timeout option', finish => {
    const request = http.get({ port, path: '/slow', timeout: 150 }, () => finish('answered'));
    request.on('timeout', () => { request.destroy(); finish('timeout fired'); });
    request.on('error', () => {});
  });
  // request.setTimeout is the same contract by another name.
  await race('http setTimeout method', finish => {
    const request = http.get({ port, path: '/slow' }, () => finish('answered'));
    request.setTimeout(150, () => { request.destroy(); finish('setTimeout fired'); });
    request.on('error', () => {});
  });

  await race('readline crlfDelay', finish => {
    const lines = [];
    const rl = readline.createInterface({ input: Readable.from(['a\r\nb\r\n']), crlfDelay: Infinity });
    rl.on('line', l => lines.push(l));
    rl.on('close', () => finish(JSON.stringify(lines)));
  });

  server.closeAllConnections();
  server.close();
  console.log(out.join('\n'));
  process.exit(0);
})();
