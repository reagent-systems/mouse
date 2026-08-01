const http = require('http');
const out = [];
// The distinction that is the whole reason node has two methods: an in-flight request must
// SURVIVE closeIdleConnections, and closeAllConnections must kill it without waiting.
let release = null;
const server = http.createServer((req, res) => {
  if (req.url === '/slow') { release = () => res.end('slow done'); return; }
  res.end('quick');
});
server.listen(0, () => {
  const port = server.address().port;
  const agent = new http.Agent({ keepAlive: true });
  http.get({ port, path: '/quick', agent }, first => {
    first.resume();
    first.on('end', () => {
      out.push('methods present: ' + (typeof server.closeIdleConnections === 'function') +
               ' ' + (typeof server.closeAllConnections === 'function'));
      const slow = http.get({ port, path: '/slow' }, res => {
        let body = '';
        res.on('data', c => body += c);
        res.on('end', () => {
          out.push('in-flight survived closeIdleConnections: ' + (body === 'slow done'));
          finish();
        });
      });
      slow.on('error', e => { out.push('slow errored: ' + e.code); finish(); });
      // Once the slow request is at the handler, drop only the IDLE keep-alive socket.
      setTimeout(() => {
        if (server.closeIdleConnections) server.closeIdleConnections();
        setTimeout(() => release && release(), 60);
      }, 90);
    });
  });
  const finish = () => {
    // Now a second in-flight request, killed outright.
    const doomed = http.get({ port, path: '/slow' }, () => { out.push('doomed answered'); done(); });
    doomed.on('error', e => { out.push('closeAllConnections killed in-flight: ' + (e.code === 'ECONNRESET')); done(); });
    setTimeout(() => { if (server.closeAllConnections) server.closeAllConnections(); }, 80);
    const done = () => {
      agent.destroy();
      server.close();
      console.log(out.join('\n'));
      process.exit(0);
    };
  };
});
