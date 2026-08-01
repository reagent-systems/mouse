// The error-path events. These fire only when something goes wrong, which makes them the ones
// least likely to be implemented and the most costly to be missing — a server that cannot
// report a malformed request or a taken port fails silently instead of loudly.
const net = require('net'), http = require('http');
const out = [];
const done = () => { console.log(out.sort().join('\n')); process.exit(0); };

// 1. EADDRINUSE: a second listen on a taken port must emit 'error' with the code.
const a = net.createServer();
a.listen(0, '127.0.0.1', () => {
  const port = a.address().port;
  const b = net.createServer();
  b.on('error', e => { out.push('server error code=' + e.code); step2(port); });
  b.listen(port, '127.0.0.1');
});

function step2(_) {
  // 2. clientError: garbage down an HTTP connection.
  const hs = http.createServer((q, r) => r.end('ok'));
  hs.on('clientError', (err, socket) => {
    out.push('clientError code=' + (err.code || err.message.slice(0, 24)) + ' hasSocket=' + !!socket);
    try { socket.destroy(); } catch (e) {}
    hs.close(); step3();
  });
  hs.listen(0, '127.0.0.1', () => {
    const raw = net.connect(hs.address().port, '127.0.0.1', () => raw.write('NOT-HTTP /\r\n\r\n'));
    raw.on('error', () => {});
    setTimeout(() => { try { raw.destroy(); } catch (e) {} if (!out.some(l => l.startsWith('clientError'))) { out.push('clientError NOT EMITTED'); hs.close(); step3(); } }, 400);
  });
}

function step3() {
  // 3. socket timeout: an idle connection past setTimeout must emit 'timeout'.
  const s = net.createServer(c => { /* never answer */ });
  s.listen(0, '127.0.0.1', () => {
    const c = net.connect(s.address().port, '127.0.0.1');
    c.setTimeout(60);
    c.on('timeout', () => { out.push('socket timeout fired'); c.destroy(); s.close(); step4(); });
    setTimeout(() => { if (!out.some(l => l.startsWith('socket timeout'))) { out.push('socket timeout NOT FIRED'); c.destroy(); s.close(); step4(); } }, 600);
  });
}

function step4() {
  // With no clientError listener node's DEFAULT answers 400 and closes, so the peer is told
  // rather than left waiting on a connection that will never reply.
  const bare = http.createServer((q, r) => r.end('ok'));
  bare.listen(0, '127.0.0.1', () => {
    const raw = net.connect(bare.address().port, '127.0.0.1', () => raw.write('NOT-HTTP /\r\n\r\n'));
    let got = '';
    raw.on('data', d => { got += d; });
    raw.on('error', () => {});
    raw.on('close', () => {
      out.push('default reply: ' + (got.startsWith('HTTP/1.1 400') ? '400 and closed' : JSON.stringify(got.slice(0, 20))));
      bare.close(); step5();
    });
    setTimeout(() => { try { raw.destroy(); } catch (e) {} }, 500);
  });
}

function step5() {
  // 4. connect to a closed port: ECONNREFUSED on the client.
  const c = net.connect(1, '127.0.0.1');
  c.on('error', e => { out.push('refused code=' + e.code); done(); });
  setTimeout(() => { if (!out.some(l => l.startsWith('refused'))) { out.push('refused NOT EMITTED'); done(); } }, 600);
}
