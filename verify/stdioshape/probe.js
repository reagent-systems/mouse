// process.stdout/stderr are Writables and stdin is a Readable in node, and code branches on
// `instanceof` — the same fault the zlib coder classes had. Behaviour must be untouched: these
// carry every program's output, so the write path matters far more than the prototype.
const { Writable, Readable } = require('stream');
const out = [];
out.push('stdout instanceof Writable: ' + (process.stdout instanceof Writable));
out.push('stderr instanceof Writable: ' + (process.stderr instanceof Writable));
out.push('stdin instanceof Readable: ' + (process.stdin instanceof Readable));
out.push('write returns true: ' + (process.stdout.write('') === true));
out.push('isTTY preserved: ' + (typeof process.stdout.isTTY));
out.push('has columns: ' + ('columns' in process.stdout));
out.push('destroy present: ' + (typeof process.stdout.destroy));
out.push('setDefaultEncoding present: ' + (typeof process.stdout.setDefaultEncoding));
out.push('on returns this: ' + (process.stdout.on('x', () => {}) === process.stdout));
// The thing that actually matters: ORDER. Output must not be reordered by the new prototype.
console.log('ordered-1');
process.stdout.write('ordered-2\n');
console.log('ordered-3');
out.push('pipe target: ' + (typeof process.stdout.write === 'function'));
console.log(out.join('\n'));
