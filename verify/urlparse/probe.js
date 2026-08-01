// url.parse is the sibling of url.format, and the same consumers use both — follow-redirects
// parses the current URL and formats the next one. A regex approximation gets the common case
// right and the rest silently wrong.
const url = require('url');
const cases = ['http://h:8080/a/b?q=1#f','https://u:p@h/x','http://h','//h/p','/just/a/path',
               'mailto:a@b.com','http://h:80/','ws://h:81/s?a=1','http://[::1]:9/v6',
               'file:///tmp/x','http://h/p?a=1&b=2','http://h/#only-hash','http://h/p#f?not-query'];
for (const c of cases) {
  const p = url.parse(c);
  console.log(c + ' -> ' + JSON.stringify({ protocol: p.protocol, host: p.host, hostname: p.hostname,
    port: p.port, pathname: p.pathname, search: p.search, hash: p.hash, path: p.path }));
}
