// axios is the most-used HTTP client in Node, and it exercises the parts of the client this
// session just changed: it builds its own Agent, sets headers, follows redirects, parses JSON,
// streams responses, and surfaces HTTP errors as rejections. A library-level proof of the agent
// work, rather than another hand-written request.
const axios = require('./project/node_modules/axios');
const http = require('http');
const out = [];

const server = http.createServer((req, res) => {
  if (req.url === '/json') { res.setHeader('content-type', 'application/json'); res.end('{"ok":true,"n":42}'); return; }
  if (req.url === '/echo') {
    let body = ''; req.on('data', c => { body += c; });
    req.on('end', () => { res.setHeader('content-type', 'application/json');
      res.end(JSON.stringify({ method: req.method, body: body, ct: req.headers['content-type'] || null,
                               custom: req.headers['x-probe'] || null })); });
    return;
  }
  if (req.url === '/redirect') { res.writeHead(302, { location: '/json' }); res.end(); return; }
  if (req.url === '/boom') { res.writeHead(500); res.end('server error'); return; }
  if (req.url === '/slow') { setTimeout(() => res.end('late'), 300); return; }
  res.end('root');
});

server.listen(0, '127.0.0.1', async () => {
  const base = 'http://127.0.0.1:' + server.address().port;
  try {
    const r1 = await axios.get(base + '/json');
    out.push('json: status=' + r1.status + ' ok=' + r1.data.ok + ' n=' + r1.data.n + ' type=' + typeof r1.data);
    out.push('headers readable: ' + (r1.headers['content-type'] || '').slice(0, 16));

    const r2 = await axios.post(base + '/echo', { hello: 'world' }, { headers: { 'X-Probe': 'yes' } });
    out.push('post: method=' + r2.data.method + ' body=' + r2.data.body + ' custom=' + r2.data.custom);
    out.push('post content-type: ' + r2.data.ct);

    const r3 = await axios.get(base + '/redirect');
    out.push('redirect followed: status=' + r3.status + ' ok=' + r3.data.ok);

    try { await axios.get(base + '/boom'); out.push('500: NO THROW'); }
    catch (e) { out.push('500 rejects: status=' + (e.response && e.response.status) + ' isAxiosError=' + !!e.isAxiosError); }

    try { await axios.get(base + '/slow', { timeout: 50 }); out.push('timeout: NO THROW'); }
    catch (e) { out.push('timeout rejects: code=' + e.code); }

    const r6 = await axios.get(base + '/json', { responseType: 'text' });
    out.push('responseType text: ' + (typeof r6.data) + ' ' + r6.data);

    const instance = axios.create({ baseURL: base, headers: { 'X-Probe': 'inst' } });
    const r7 = await instance.post('/echo', 'raw body');
    out.push('instance: custom=' + r7.data.custom + ' body=' + r7.data.body);
  } catch (e) {
    out.push('UNEXPECTED: ' + e.message.slice(0, 90));
  }
  server.close();
  console.log(out.join('\n'));
});
