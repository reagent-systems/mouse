const fs = require('fs');
const net = require('net');
const http = require('http');
const dns = require('dns');
const { spawn } = require('child_process');
const out = [];
const mark = tag => { Promise.resolve().then(() => out.push(tag + ':promise')); process.nextTick(() => out.push(tag + ':tick')); };

// Each of these reaches user code by a DIFFERENT route out of the host.
fs.readFile(process.argv[1], () => {
  mark('fs');
  dns.lookup('localhost', { family: 4 }, () => {
    mark('dns');
    const watched = 'watch-probe.txt';
    fs.writeFileSync(watched, 'a');
    const watcher = fs.watch(watched, () => {
      watcher.close();
      mark('watch');
      const server = http.createServer((req, res) => res.end('hi'));
      server.listen(0, () => {
        http.get({ port: server.address().port, path: '/' }, res => {
          mark('http-response');
          res.resume();
          res.on('end', () => {
            server.close();
            const child = spawn('node', ['-e', 'process.exit(0)']);
            child.on('exit', () => {
              mark('child-exit');
              const srv = net.createServer(c => c.end('x')).listen(0, () => {
                const client = net.connect(srv.address().port, '127.0.0.1');
                client.on('data', () => mark('sock'));
                client.on('close', () => {
                  srv.close();
                  setTimeout(() => {
                    // Report pairs in order: every tag must show tick BEFORE promise.
                    const tags = [...new Set(out.map(v => v.split(':')[0]))];
                    console.log(tags.map(t => t + '=' + (out.indexOf(t + ':tick') < out.indexOf(t + ':promise') ? 'tick-first' : 'PROMISE-FIRST')).join(' '));
                  }, 30);
                });
              });
            });
          });
        });
      });
    });
    setTimeout(() => fs.writeFileSync(watched, 'b'), 60);
  });
});
