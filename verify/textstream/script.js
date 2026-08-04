const out = [];
(async () => {
  // The case a per-chunk decode gets wrong: a multi-byte character split across chunks.
  const rs = new ReadableStream({ start(c) {
    c.enqueue(new Uint8Array([0xe2, 0x82]));   // first two bytes of €
    c.enqueue(new Uint8Array([0xac, 0x41]));   // its last byte, then 'A'
    c.close();
  } });
  const reader = rs.pipeThrough(new TextDecoderStream()).getReader();
  const parts = [];
  for (;;) { const { value, done } = await reader.read(); if (done) break; parts.push(value); }
  out.push('decoded across chunk boundary: ' + JSON.stringify(parts.join('')));

  const es = new ReadableStream({ start(c) { c.enqueue('hi'); c.close(); } });
  const er = es.pipeThrough(new TextEncoderStream()).getReader();
  const first = await er.read();
  out.push('encoded: ' + JSON.stringify(Array.from(first.value)));
  out.push('sides are objects: ' + (typeof new TextDecoderStream().readable) + ' ' +
                                   (typeof new TextDecoderStream().writable));

  // The decoder's own streaming contract, used directly.
  const d = new TextDecoder();
  out.push('partial then rest: ' + JSON.stringify(d.decode(new Uint8Array([0xe2, 0x82]), { stream: true })) +
           ' ' + JSON.stringify(d.decode(new Uint8Array([0xac]), { stream: true })));
  out.push('fatal/ignoreBOM present: ' + (new TextDecoder('utf-8', { fatal: true }).fatal) + ' ' +
           (new TextDecoder('utf-8', { ignoreBOM: true }).ignoreBOM));

  // encodeInto reports what fit and never splits a character.
  const target = new Uint8Array(4);
  out.push('encodeInto: ' + JSON.stringify(new TextEncoder().encodeInto('a€b', target)) +
           ' bytes=' + JSON.stringify(Array.from(target)));
  const tight = new Uint8Array(2);
  out.push('encodeInto tight: ' + JSON.stringify(new TextEncoder().encodeInto('€', tight)));
  console.log(out.join('\n'));
})().catch(e => console.log('THREW ' + e.message));
