const { Readable } = require('stream');
const http = require('http');
// 1. The most common CLI idiom there is: pipe something to stdout.
Readable.from(['piped ', 'to ', 'stdout\n']).pipe(process.stdout);
process.stdout.on('error', () => {});
setTimeout(() => {
  console.log('stdout is a Writable:', typeof process.stdout.pipe === 'function',
              typeof process.stdout.end === 'function', typeof process.stdout.destroy === 'function');
  // 2. server.close() with an idle keep-alive client: does it ever finish?
  const server = http.createServer((req, res) => res.end('ok'));
  server.listen(0, () => {
    const agent = new http.Agent({ keepAlive: true });
    http.get({ port: server.address().port, path: '/', agent }, res => {
      res.resume();
      res.on('end', () => {
        let closed = false;
        server.close(() => { closed = true; });
        setTimeout(() => {
          console.log('close() finished with an idle keep-alive client:', closed);
          console.log('has closeIdleConnections:', typeof server.closeIdleConnections === 'function');
          if (typeof server.closeIdleConnections === 'function') server.closeIdleConnections();
          agent.destroy();
          setTimeout(() => { console.log('done'); process.exit(0); }, 60);
        }, 250);
      });
    });
  });
}, 80);
