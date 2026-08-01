// Every stream-LIKE object the engine hands out, checked against the same contract. The lesson
// that prompted this: a behaviour can live in several implementations that drift. process.stdin
// and process.stdout are hand-rolled here rather than real Readable/Writable, so they are the
// likeliest to have quietly diverged.
const fs = require('fs');
const net = require('net');
const zlib = require('zlib');
const { Readable, Writable } = require('stream');
const out = [];
const readableAPI = ['pipe', 'unpipe', 'on', 'once', 'read', 'pause', 'resume', 'setEncoding',
                     'destroy', 'map', 'filter', 'toArray', 'isPaused', 'unshift', 'push'];
const writableAPI = ['write', 'end', 'on', 'once', 'destroy', 'cork', 'uncork', 'setDefaultEncoding'];
const report = (label, value, names) =>
  out.push(label + ' missing: ' + (names.filter(n => typeof value[n] !== 'function').join(',') || 'none'));

fs.rmSync('sk', { recursive: true, force: true });
fs.mkdirSync('sk');
fs.writeFileSync('sk/f.txt', 'x');

report('stream.Readable', new Readable({ read() {} }), readableAPI);
report('stream.Writable', new Writable({ write(c, e, cb) { cb(); } }), writableAPI);
report('fs read stream', fs.createReadStream('sk/f.txt'), readableAPI);
report('fs write stream', fs.createWriteStream('sk/w.txt'), writableAPI);
report('zlib gzip', zlib.createGzip(), readableAPI);
report('process.stdin', process.stdin, readableAPI);
report('process.stdout', process.stdout, writableAPI);
report('process.stderr', process.stderr, writableAPI);
report('net.Socket readable', new net.Socket(), readableAPI);
report('net.Socket writable', new net.Socket(), writableAPI);
// An http request and response are streams too.
const http = require('http');
const server = http.createServer((req, res) => {
  report('http IncomingMessage', req, readableAPI);
  report('http ServerResponse', res, writableAPI);
  res.end('ok');
});
server.listen(0, () => {
  const request = http.get({ port: server.address().port, path: '/' }, response => {
    report('http client response', response, readableAPI);
    report('http ClientRequest', request, writableAPI);
    response.resume();
    response.on('end', () => {
      fs.rmSync('sk', { recursive: true, force: true });
      server.close();
      console.log(out.join('\n'));
      process.exit(0);
    });
  });
});
