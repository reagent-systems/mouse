const zlib = require('zlib');
const sample = Buffer.from('brotli '.repeat(500) + 'tail');
const packed = zlib.brotliCompressSync(sample);
console.log('round trip:', zlib.brotliDecompressSync(packed).equals(sample));
console.log('smaller than input:', packed.length < sample.length);
// Corrupt input must be an error, not silence.
try { zlib.brotliDecompressSync(Buffer.from('not brotli at all')); console.log('corrupt: ALLOWED'); }
catch (error) { console.log('corrupt input errors:', error instanceof Error); }
// The stream forms, fed in pieces: a partial brotli stream is not decodable alone, so this is
// the case a one-shot-behind-a-stream-API fake would fail.
const compressor = zlib.createBrotliCompress();
const chunks = [];
compressor.on('data', c => chunks.push(c));
compressor.on('end', () => {
  const streamed = Buffer.concat(chunks);
  const decompressor = zlib.createBrotliDecompress();
  const back = [];
  decompressor.on('data', c => back.push(c));
  decompressor.on('end', () => {
    console.log('stream round trip:', Buffer.concat(back).equals(sample));
    console.log('stream output decodes one-shot:', zlib.brotliDecompressSync(streamed).equals(sample));
  });
  // Feed the decompressor in small pieces too.
  for (let i = 0; i < streamed.length; i += 7) decompressor.write(streamed.slice(i, i + 7));
  decompressor.end();
});
for (let i = 0; i < sample.length; i += 111) compressor.write(sample.slice(i, i + 111));
compressor.end();
