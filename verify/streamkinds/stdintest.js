// The commonest way a CLI reads piped input.
(async () => {
  const parts = [];
  for await (const chunk of process.stdin) parts.push(String(chunk));
  console.log('for-await over stdin: ' + JSON.stringify(parts.join('')));
  console.log('has asyncIterator: ' + (typeof process.stdin[Symbol.asyncIterator] === 'function'));
})().catch(e => console.log('THREW: ' + e.message));
