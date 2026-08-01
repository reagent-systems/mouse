// querystring is url's sibling: same legacy era, same consumers, and the same risk of being
// present, callable and quietly wrong. Note node uses %20 for a space, NOT '+' — the difference
// matters to anything signing or comparing a query string.
const qs = require('querystring');
const parses = ['a=1&b=2','a=1&a=2','a','a=','=v','a=1&&b=2','a%20b=c%26d','a[]=1&a[]=2',
                'a=%E6%97%A5','+a+=+b+','a=1;b=2',''];
for (const p of parses) console.log('parse ' + JSON.stringify(p) + ' -> ' + JSON.stringify(qs.parse(p)));
const stringifies = [{a:1,b:2},{a:[1,2]},{a:'x y'},{a:'a&b'},{a:null},{a:true},{a:''},{'a b':'c'},{a:'日'}];
for (const o of stringifies) console.log('stringify ' + JSON.stringify(o) + ' -> ' + JSON.stringify(qs.stringify(o)));
console.log('escape -> ' + qs.escape('a b&c=d日'));
console.log('unescape -> ' + qs.unescape('a%20b%26c'));
console.log('custom sep/eq -> ' + JSON.stringify(qs.parse('a:1;b:2', ';', ':')));
console.log('stringify sep/eq -> ' + qs.stringify({a:1,b:2}, ';', ':'));
