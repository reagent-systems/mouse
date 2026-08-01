const fs = require('fs');
// Build the tree in-process so the fixture carries its own world.
for (const dir of ['g/src/deep', 'g/lib', 'g/.hidden']) fs.mkdirSync(dir, { recursive: true });
for (const f of ['g/a.js', 'g/b.ts', 'g/src/c.js', 'g/src/d.ts', 'g/src/deep/e.js', 'g/lib/f.js', 'g/.hidden/h.js', 'g/.dot.js']) {
  fs.writeFileSync(f, 'x');
}
for (const pattern of ['*.js', '**/*.js', 'src/*.js', '**/*.ts', '*', 'src/**', '**/deep/*.js', '*.{js,ts}', '[al]*']) {
  console.log(pattern + ' -> ' + JSON.stringify(fs.globSync(pattern, { cwd: 'g' }).sort()));
}
fs.glob('**/*.js', { cwd: 'g' }, (error, found) => {
  console.log('async -> ' + (error ? 'error ' + error.code : JSON.stringify(found.sort())));
  // Both refusals name a measured reason rather than a guess.
  try { fs.globSync('*', { cwd: 'g', exclude: () => false }); console.log('exclude: ALLOWED'); }
  catch (e) { console.log('exclude refused, reason named: ' + /entry name|relative path/.test(e.message)); }
  try { require('path').matchesGlob('a.js', '*.js'); console.log('matchesGlob: ALLOWED'); }
  catch (e) { console.log('matchesGlob refused, reason named: ' + /experimental|self-inconsistent/.test(e.message)); }
});
