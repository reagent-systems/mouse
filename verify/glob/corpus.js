// Every pattern crossed with every path: a corpus, not a handful of cases the author liked.
const patterns = [
  '*', '**', '*.js', '*.ts', '**/*.js', '**/*', 'a', 'a/*', 'a/**', 'a/**/*.js', 'a/*/c',
  '?', '?.js', '??.js', 'a?c', '[abc]', '[abc].js', '[!abc].js', '[^abc].js', '[a-c].js',
  '[0-9].js', 'a[-]b', 'a[]]b', '{a,b}', '{a,b}.js', '*.{js,ts}', '{a,b}/{c,d}', 'a{b,c}d',
  '**/b', '**/b/**', 'a/**/b', '*/*', '*/*/*', 'a/b/c', '.*', '.a', 'a/.b', '**/.b',
  'a/', 'A*', '*A', 'a*b*c', '*.*', 'a.*', '[[]', 'a**b', '**a', 'a**',
];
const paths = [
  '', 'a', 'b', 'a.js', 'b.js', 'ab.js', 'abc.js', 'a.ts', 'a.txt', 'A.JS', 'a1.js',
  'a/b', 'a/b.js', 'a/b/c', 'a/b/c.js', 'a/b/c/d.js', 'a/c', 'b/c', 'x/y/z.ts',
  '.a', '.hidden', 'a/.b', 'a/.b/c', '.a/b', 'a-b', 'a]b', 'a b', 'ad', 'abd', 'acd',
  'a/', 'aXb', 'aab', 'ba', 'aa', 'c/d', 'a/d', 'b/d',
];
const path = require('path');
const results = [];
for (const pattern of patterns) {
  for (const target of paths) {
    let value;
    try { value = path.matchesGlob(target, pattern); } catch (error) { value = 'throw:' + (error.code || error.name); }
    results.push(pattern + '\t' + target + '\t' + value);
  }
}
console.log('cases: ' + results.length);
console.log(results.join('\n'));
