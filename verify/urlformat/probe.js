// url.format is how follow-redirects rebuilds a redirect target, so a dropped port here sends
// the next hop to the wrong server entirely.
const url = require('url');
const cases = [
 {protocol:'http:',hostname:'127.0.0.1',port:8080,path:'/a?b=1'},
 {protocol:'http:',hostname:'h',port:80,pathname:'/p'},
 {protocol:'https:',host:'h:443',pathname:'/x',search:'?q=1'},
 {protocol:'http:',hostname:'h',pathname:'/p',hash:'#f'},
 {protocol:'http:',hostname:'h',port:3000},
 {protocol:'http:',auth:'u:p',hostname:'h',port:1,pathname:'/z'},
 {protocol:'mailto:',pathname:'a@b.com'},
 {host:'h:9',pathname:'/n'},
 {protocol:'http:',hostname:'h',query:{a:'1',b:'two words'},pathname:'/q'},
 {protocol:'ws:',hostname:'h',port:81,pathname:'/sock'},
];
for (const c of cases) console.log(JSON.stringify(c).slice(0, 52) + ' -> ' + url.format(c));
