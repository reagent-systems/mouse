// Gaps the `shapes` investigation had been listing. Most of its entries are node internals
// (readableBuffer, hexWrite and friends); these four are public API that was simply absent.
const out = [];
out.push('prependOnceListener: ' + typeof process.prependOnceListener);
let order = [];
process.prependOnceListener('probe', () => order.push('prepended'));
process.on('probe', () => order.push('normal'));
process.emit('probe'); process.emit('probe');
out.push('prepend runs first and once: ' + order.join(','));
out.push('stdout fd: ' + process.stdout.fd + ' writable: ' + process.stdout.writable + ' readable: ' + process.stdout.readable);
out.push('stderr fd: ' + process.stderr.fd);
out.push('stdin fd: ' + process.stdin.fd + ' readable: ' + process.stdin.readable);
out.push('Response.formData: ' + typeof new Response('x').formData);
new Response('a=1&b=two+words', { headers: { 'content-type': 'application/x-www-form-urlencoded' } })
  .formData().then(f => {
    out.push('urlencoded: ' + f.get('a') + ' | ' + f.get('b'));
    const body = '--X\r\nContent-Disposition: form-data; name="field"\r\n\r\nvalue\r\n--X--\r\n';
    return new Response(body, { headers: { 'content-type': 'multipart/form-data; boundary=X' } }).formData();
  })
  .then(f => { out.push('multipart: ' + f.get('field')); console.log(out.join('\n')); });
