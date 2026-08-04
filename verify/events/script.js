// The EVENT SEQUENCE audit. Real code waits on events, so one that never fires is a hang and one
// that fires twice is a double-free. Ordering matters too: 'end' before 'close', 'response'
// before 'end'. Each case records the exact ordered list and is compared with node's.
const fs = require('fs');
const net = require('net');
const http = require('http');
const zlib = require('zlib');
const { Readable, Writable } = require('stream');
const out = [];
const watch = (emitter, names) => {
  const seen = [];
  for (const name of names) emitter.on(name, () => seen.push(name));
  return seen;
};
const race = (label, build) => new Promise(resolve => {
  let settled = false;
  const finish = seen => { if (!settled) { settled = true; out.push(label + ': ' + seen.join(',')); resolve(); } };
  const timer = setTimeout(() => finish(['TIMED OUT']), 1500);
  try { build(seen => { clearTimeout(timer); finish(seen); }); }
  catch (e) { clearTimeout(timer); finish(['THREW ' + String(e.message).slice(0, 30)]); }
});

fs.rmSync('ev', { recursive: true, force: true });
fs.mkdirSync('ev');
fs.writeFileSync('ev/f.txt', 'hello');

(async () => {
  await race('read stream', finish => {
    const stream = fs.createReadStream('ev/f.txt');
    const seen = watch(stream, ['open', 'ready', 'data', 'end', 'close', 'error']);
    stream.on('close', () => setImmediate(() => finish(seen)));
    stream.resume();
  });
  await race('write stream', finish => {
    const stream = fs.createWriteStream('ev/w.txt');
    const seen = watch(stream, ['open', 'ready', 'finish', 'close', 'error']);
    stream.on('close', () => setImmediate(() => finish(seen)));
    stream.end('x');
  });
  await race('read stream missing file', finish => {
    const stream = fs.createReadStream('ev/nope.txt');
    const seen = watch(stream, ['open', 'ready', 'data', 'end', 'close', 'error']);
    stream.on('error', () => setTimeout(() => finish(seen), 60));
  });
  await race('gzip stream', finish => {
    const gz = zlib.createGzip();
    const seen = watch(gz, ['data', 'end', 'finish', 'close', 'error']);
    gz.on('close', () => setImmediate(() => finish(seen)));
    gz.resume();
    gz.end('payload');
  });
  await race('client socket', finish => {
    const server = net.createServer(c => c.end('hi'));
    server.listen(0, () => {
      const socket = net.connect(server.address().port, '127.0.0.1');
      const seen = watch(socket, ['connect', 'ready', 'data', 'end', 'close', 'error']);
      socket.on('close', () => { server.close(); setImmediate(() => finish(seen)); });
      socket.resume();
    });
  });
  await race('server lifecycle', finish => {
    const server = net.createServer(c => c.end());
    const seen = watch(server, ['listening', 'connection', 'close', 'error']);
    server.listen(0, () => {
      const socket = net.connect(server.address().port, '127.0.0.1');
      socket.resume();
      socket.on('close', () => { server.close(); });
    });
    server.on('close', () => setImmediate(() => finish(seen)));
  });
  await race('http client request', finish => {
    const server = http.createServer((req, res) => res.end('ok'));
    server.listen(0, () => {
      const request = http.get({ port: server.address().port, path: '/' });
      const seen = watch(request, ['socket', 'response', 'close', 'error']);
      request.on('response', res => {
        res.resume();
        res.on('end', () => { seen.push('res-end'); server.close(); setTimeout(() => finish(seen), 80); });
      });
    });
  });
  await race('http server side', finish => {
    const seen = [];
    const server = http.createServer((req, res) => {
      seen.push('request');
      req.on('end', () => seen.push('req-end'));
      res.on('finish', () => seen.push('res-finish'));
      req.resume();
      res.end('ok');
    });
    server.listen(0, () => {
      http.get({ port: server.address().port, path: '/' }, res => {
        res.resume();
        res.on('end', () => { server.close(); setTimeout(() => finish(seen), 80); });
      });
    });
  });
  await race('writable end twice', finish => {
    const seen = [];
    const sink = new Writable({ write(c, e, cb) { cb(); } });
    sink.on('finish', () => seen.push('finish'));
    sink.on('close', () => seen.push('close'));
    sink.end('a');
    setTimeout(() => finish(seen), 100);
  });
  fs.rmSync('ev', { recursive: true, force: true });
  console.log(out.join('\n'));
  process.exit(0);
})();
