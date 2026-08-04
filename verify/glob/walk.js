const fs = require('fs');
// The API programs actually call: walk a real tree and report what matches.
for (const pattern of ['*.js', '**/*.js', 'src/*.js', '**/*.ts', '*', 'src/**', '**/deep/*.js']) {
  const found = fs.globSync(pattern, { cwd: 'tree' }).map(p => p.split('\\').join('/')).sort();
  console.log(pattern + ' -> ' + JSON.stringify(found));
}
fs.glob('**/*.js', { cwd: 'tree' }, (error, found) => {
  console.log('async -> ' + (error ? 'error ' + error.code : JSON.stringify(found.map(p => p.split('\\').join('/')).sort())));
});
