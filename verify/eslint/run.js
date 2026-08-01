// eslint through its Node API: config loading, a recursive walk of src/**, module resolution
// across ~14 MB of dependencies, then rule execution.
const { ESLint } = require('eslint');
(async () => {
  const eslint = new ESLint({ cwd: process.cwd() });
  const results = await eslint.lintFiles(['src/**/*.js']);
  const lines = [];
  for (const r of results.sort((a, b) => a.filePath.localeCompare(b.filePath))) {
    lines.push(r.filePath.split('/').pop() + ': ' + r.errorCount + ' errors, ' + r.warningCount + ' warnings');
    for (const m of r.messages) lines.push('  ' + m.ruleId + ' @' + m.line + ': ' + m.message);
  }
  console.log(lines.join('\n'));
})().catch(e => console.log('THREW ' + e.message.slice(0, 200)));
