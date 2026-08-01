// Every zlib coder exists in BOTH forms in node — a factory and a class — and code branches on
// `instanceof`. Brotli had no class at all, and the factories produced plain Transforms, so the
// instanceof half was false across the board.
const zlib = require('zlib'), { Transform } = require('stream');
const out = [];
const names = ['Gzip', 'Gunzip', 'Deflate', 'Inflate', 'DeflateRaw', 'InflateRaw', 'Unzip',
               'BrotliCompress', 'BrotliDecompress'];
for (const name of names) {
  const Klass = zlib[name];
  const factory = zlib['create' + name];
  let line = name + ': class=' + typeof Klass + ' factory=' + typeof factory;
  try {
    const viaNew = new Klass();
    const viaFactory = factory();
    line += ' new=' + (viaNew instanceof Klass) + ' factory=' + (viaFactory instanceof Klass) +
            ' transform=' + (viaNew instanceof Transform) + ' writable=' + (typeof viaNew.write);
  } catch (e) { line += ' THREW ' + String(e.message).slice(0, 40); }
  out.push(line);
}
// The classes must still CODE, not merely exist: a round trip through the constructor form.
const { pipeline, Readable } = require('stream');
const payload = Buffer.from('brotli through the constructor form, repeated. '.repeat(20));
pipeline(Readable.from([payload]), new zlib.BrotliCompress(), new zlib.BrotliDecompress(),
  (() => { const chunks = []; const sink = new (require('stream').Writable)({
      write(c, e, cb) { chunks.push(c); cb(); } });
    sink.on('finish', () => {
      out.push('brotli round trip: ' + Buffer.concat(chunks).equals(payload));
      console.log(out.join('\n'));
    });
    return sink; })(),
  (err) => { if (err) { out.push('pipeline error: ' + err.message.slice(0, 50)); console.log(out.join('\n')); } });
