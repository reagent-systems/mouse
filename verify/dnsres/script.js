const dns = require('dns');
// Live records chosen because they are stable and publicly documented. Sorted everywhere, since
// a resolver may return records in any order.
const steps = [
  cb => dns.resolveTxt('example.com', (e, r) => cb('TXT ' + (e ? 'err:' + e.code : JSON.stringify(r.map(c => c.join('')).sort())))),
  cb => dns.resolveMx('gmail.com', (e, r) => cb('MX ' + (e ? 'err:' + e.code : JSON.stringify(r.map(x => x.priority + ':' + x.exchange).sort())))),
  cb => dns.resolveNs('example.com', (e, r) => cb('NS ' + (e ? 'err:' + e.code : JSON.stringify(r.sort())))),
  cb => dns.resolveCname('www.github.com', (e, r) => cb('CNAME ' + (e ? 'err:' + e.code : JSON.stringify(r.sort())))),
  cb => dns.resolveSoa('example.com', (e, r) => cb('SOA ' + (e ? 'err:' + e.code : r.nsname + ' ' + r.hostmaster + ' refresh=' + r.refresh))),
  cb => dns.resolveSrv('_xmpp-server._tcp.gmail.com', (e, r) => cb('SRV ' + (e ? 'err:' + e.code : JSON.stringify(r.map(x => x.priority + ':' + x.port + ':' + x.name).sort())))),
  cb => dns.resolveCaa('google.com', (e, r) => cb('CAA ' + (e ? 'err:' + e.code : JSON.stringify(r.map(x => JSON.stringify(x)).sort())))),
  cb => dns.reverse('8.8.8.8', (e, r) => cb('reverse ' + (e ? 'err:' + e.code : JSON.stringify(r.sort())))),
  cb => dns.lookupService('8.8.8.8', 443, (e, host, service) => cb('service ' + (e ? 'err:' + e.code : host + ' ' + service))),
  cb => dns.resolve('example.com', 'TXT', (e, r) => cb('resolve-TXT ' + (e ? 'err:' + e.code : JSON.stringify(r.map(c => c.join('')).sort())))),
  cb => dns.resolveTxt('this-name-does-not-exist-mouse.invalid', (e, r) => cb('missing ' + (e ? 'err:' + e.code : 'no error'))),
];
// Sequential so the output order is fixed rather than a race.
const out = [];
(function next(i) {
  if (i >= steps.length) { console.log(out.join('\n')); return; }
  steps[i](line => { out.push(line); next(i + 1); });
})(0);
