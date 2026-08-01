// The third legacy url function the redirect path uses. `resolve` decides where a relative
// Location header actually points, and `urlToHttpOptions` is how a WHATWG URL becomes
// http.request options — both sit between a redirect and the socket it opens.
const url = require('url');
const cases = [['http://h/a/b','c'],['http://h/a/b','/c'],['http://h/a/b','../c'],['http://h/a/b','?q=1'],
 ['http://h/a/b','#f'],['http://h/a/b','//other/x'],['http://h/a/b','https://z/y'],['http://h/a/','.'],
 ['http://h:8080/a','b'],['/base/path','sub']];
for (const [b, r] of cases) console.log(b + ' + ' + r + ' -> ' + url.resolve(b, r));
const o = url.urlToHttpOptions(new URL('http://u:p@h:8080/a/b?q=1#f'));
console.log('urlToHttpOptions -> ' + JSON.stringify(o));
const plain = url.urlToHttpOptions(new URL('https://h/x'));
console.log('urlToHttpOptions plain -> ' + JSON.stringify(plain));
