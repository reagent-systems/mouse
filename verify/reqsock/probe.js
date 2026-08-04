// The last public clusters the shapes sweep names: the fetch Request surface, and the socket
// state node reports. Values node actually returns, not plausible-looking defaults.
const net = require('net');
const out = [];
const r = new Request('https://x/y', { method: 'POST', body: 'b' });
out.push('Request: ' + ['method','mode','credentials','cache','redirect','referrer','referrerPolicy','integrity','keepalive','destination','duplex','isHistoryNavigation','isReloadNavigation'].map(k => k + '=' + JSON.stringify(r[k])).join(' '));
const custom = new Request('https://x/y', { mode: 'no-cors', credentials: 'include', keepalive: true, integrity: 'sha256-x' });
out.push('Request custom: ' + ['mode','credentials','keepalive','integrity'].map(k => k + '=' + JSON.stringify(custom[k])).join(' '));
const srv = net.createServer(s => {
  out.push('accepted: server===listener ' + (s.server === srv) + ' bufferSize=' + s.bufferSize +
           ' family=' + s.localFamily + ' resetAndDestroy=' + typeof s.resetAndDestroy);
  s.end();
});
srv.listen(0, '127.0.0.1', () => {
  const c = net.connect(srv.address().port, '127.0.0.1', () => {
    out.push('client: server=' + JSON.stringify(c.server) + ' bufferSize=' + c.bufferSize + ' family=' + c.localFamily);
    c.end();
  });
  c.on('close', () => { srv.close(); console.log(out.join('\n')); });
});
