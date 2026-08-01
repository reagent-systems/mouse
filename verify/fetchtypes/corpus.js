'use strict';
// The fetch VALUE TYPES — Headers, Request, Response, Blob, FormData. Every HTTP client written
// for the platform is built on these, and all of their interesting behaviour is local: header
// names fold case, a body can be read exactly once, a clone gives you a second read. None of it
// needs a network, and none of it had ever been compared with node.

function line(name, value) { console.log(name + '\t' + value); }
function show(error) {
  if (!error) return String(error);
  if (typeof error !== 'object') return typeof error + ':' + String(error);
  return (error.name || 'Error') + '/' + (error.code || 'no-code');
}
function attempt(name, fn) {
  try { line(name, String(fn())); }
  catch (error) { line(name, 'THREW ' + show(error)); }
}

// ---- Headers: names fold case, and iteration is SORTED ---------------------------------------
attempt('headers-case-insensitive', () => {
  const headers = new Headers();
  headers.set('Content-Type', 'text/plain');
  return [headers.get('content-type'), headers.get('CONTENT-TYPE'), headers.has('Content-TYPE'),
          headers.get('missing')].join(' | ');
});

attempt('headers-append-vs-set', () => {
  const headers = new Headers();
  headers.append('x-tag', 'one');
  headers.append('x-tag', 'two');
  const appended = headers.get('x-tag');
  headers.set('x-tag', 'three');
  return appended + ' -> ' + headers.get('x-tag');
});

attempt('headers-iteration-is-sorted-and-lowercased', () => {
  const headers = new Headers();
  headers.set('Zeta', '1');
  headers.set('alpha', '2');
  headers.set('Mid', '3');
  const seen = [];
  for (const [name, value] of headers) seen.push(name + '=' + value);
  return seen.join(',');
});

attempt('headers-from-object-and-pairs', () => {
  const fromObject = new Headers({ 'X-One': 'a', 'x-two': 'b' });
  const fromPairs = new Headers([['X-One', 'a'], ['x-two', 'b']]);
  const copied = new Headers(fromObject);
  return [fromObject.get('x-one'), fromPairs.get('X-TWO'), copied.get('x-one'),
          [...copied.keys()].join('+')].join(' | ');
});

attempt('headers-delete-and-forEach', () => {
  const headers = new Headers({ a: '1', b: '2' });
  headers.delete('A');
  headers.delete('nothing-here');
  const seen = [];
  headers.forEach(function (value, name) { seen.push(name + ':' + value); });
  return seen.join(',') + ' | keys=' + [...headers.keys()].join(',')
    + ' values=' + [...headers.values()].join(',')
    + ' entries=' + [...headers.entries()].map((e) => e.join('=')).join(',');
});

attempt('headers-set-cookie', () => {
  const headers = new Headers();
  headers.append('Set-Cookie', 'a=1');
  headers.append('set-cookie', 'b=2');
  const combined = headers.get('set-cookie');
  const list = typeof headers.getSetCookie === 'function' ? headers.getSetCookie() : 'no getSetCookie';
  const iterated = [...headers].map((e) => e.join('=')).join(' & ');
  return combined + ' | ' + JSON.stringify(list) + ' | ' + iterated;
});

attempt('headers-invalid-name', () => {
  const headers = new Headers();
  try { headers.set('bad name', 'x'); return 'accepted'; }
  catch (error) { return 'THREW ' + (error && error.name); }
});

// ---- Response --------------------------------------------------------------------------------
attempt('response-defaults', () => {
  const response = new Response();
  return [response.status, JSON.stringify(response.statusText), response.ok, response.type,
          JSON.stringify(response.url), response.bodyUsed, response.body === null].join(' | ');
});

attempt('response-explicit', () => {
  const response = new Response('hi', { status: 201, statusText: 'Created', headers: { 'X-A': 'b' } });
  return [response.status, response.statusText, response.ok, response.headers.get('x-a')].join(' | ');
});

attempt('response-status-guards', () => {
  const results = [];
  for (const status of [204, 205, 304]) {
    try { new Response('body', { status: status }); results.push(status + ':accepted'); }
    catch (error) { results.push(status + ':THREW ' + (error && error.name)); }
  }
  try { new Response('x', { status: 99 }); results.push('99:accepted'); }
  catch (error) { results.push('99:THREW ' + (error && error.name)); }
  return results.join(',');
});

attempt('response-statics', () => {
  const json = typeof Response.json === 'function' ? Response.json({ a: 1 }) : null;
  const redirect = typeof Response.redirect === 'function' ? Response.redirect('https://example.com/x', 302) : null;
  const errored = typeof Response.error === 'function' ? Response.error() : null;
  return [json ? json.status + '/' + json.headers.get('content-type') : 'no Response.json',
          redirect ? redirect.status + '/' + redirect.headers.get('location') : 'no Response.redirect',
          errored ? errored.type + '/' + errored.status : 'no Response.error'].join(' | ');
});

// ---- Request ---------------------------------------------------------------------------------
attempt('request-defaults', () => {
  const request = new Request('https://example.com/path');
  return [request.method, request.url, request.bodyUsed,
          typeof request.headers, request.body === null].join(' | ');
});

attempt('request-method-and-body', () => {
  const request = new Request('https://example.com/', { method: 'post', body: 'payload',
                                                        headers: { 'X-K': 'v' } });
  return [request.method, request.headers.get('x-k'), request.bodyUsed].join(' | ');
});

attempt('request-get-with-body', () => {
  try { new Request('https://example.com/', { method: 'GET', body: 'nope' }); return 'accepted'; }
  catch (error) { return 'THREW ' + (error && error.name); }
});

// ---- Blob --------------------------------------------------------------------------------------
attempt('blob-shape', () => {
  const blob = new Blob(['abc', 'de'], { type: 'text/plain' });
  return [blob.size, blob.type, typeof blob.text, typeof blob.arrayBuffer, typeof blob.slice].join(' | ');
});

attempt('blob-from-bytes', () => {
  const blob = new Blob([new Uint8Array([104, 105])]);
  return blob.size + ' type=' + JSON.stringify(blob.type);
});

// ---- FormData -----------------------------------------------------------------------------------
attempt('formdata', () => {
  const form = new FormData();
  form.append('a', '1');
  form.append('a', '2');
  form.set('b', '3');
  return [form.get('a'), JSON.stringify(form.getAll('a')), form.has('b'), form.get('missing')].join(' | ')
    + ' entries=' + [...form.entries()].map((e) => e.join('=')).join(',');
});

// ---- bodies: read once, clone for a second read ---------------------------------------------------
async function asyncScenarios() {
  const namedThen = async (name, fn) => {
    try { line(name, String(await fn())); }
    catch (error) { line(name, 'REJECTED ' + show(error)); }
  };

  await namedThen('response-text', async () => {
    const response = new Response('some text');
    const before = response.bodyUsed;
    const text = await response.text();
    return before + ' -> ' + text + ' used=' + response.bodyUsed;
  });

  await namedThen('response-json', async () => {
    const response = new Response('{"a":[1,2]}');
    return JSON.stringify(await response.json());
  });

  await namedThen('response-arrayBuffer', async () => {
    const response = new Response('bytes');
    const buffer = await response.arrayBuffer();
    return buffer.byteLength + ' ' + Buffer.from(buffer).toString();
  });

  await namedThen('body-read-twice', async () => {
    const response = new Response('once');
    await response.text();
    try { await response.text(); return 'second read allowed'; }
    catch (error) { return 'THREW ' + (error && error.name); }
  });

  await namedThen('response-clone', async () => {
    const response = new Response('shared');
    const copy = response.clone();
    const first = await response.text();
    const second = await copy.text();
    return first + '|' + second;
  });

  // Cloning a body that is still ARRIVING has to tee it: both halves see the same bytes as they
  // come in. This used to refuse outright, so it is asserted rather than assumed.
  await namedThen('clone-a-streaming-body', async () => {
    const stream = new ReadableStream({
      start(controller) {
        controller.enqueue(new TextEncoder().encode('live '));
        controller.enqueue(new TextEncoder().encode('bytes'));
        controller.close();
      },
    });
    const response = new Response(stream);
    const copy = response.clone();
    const [first, second] = await Promise.all([response.text(), copy.text()]);
    return first + '|' + second;
  });

  await namedThen('clone-after-read', async () => {
    const response = new Response('spent');
    await response.text();
    try { response.clone(); return 'clone allowed'; }
    catch (error) { return 'THREW ' + (error && error.name); }
  });

  await namedThen('request-clone-after-read', async () => {
    const request = new Request('https://example.com/', { method: 'POST', body: 'spent' });
    await request.text();
    try { request.clone(); return 'clone allowed'; }
    catch (error) { return 'THREW ' + (error && error.name); }
  });

  await namedThen('response-from-stream', async () => {
    const stream = new ReadableStream({
      start(controller) {
        controller.enqueue(new TextEncoder().encode('from '));
        controller.enqueue(new TextEncoder().encode('a stream'));
        controller.close();
      },
    });
    const response = new Response(stream);
    return await response.text();
  });

  await namedThen('response-body-is-a-web-stream', async () => {
    const response = new Response('streamed');
    const body = response.body;
    if (!body || typeof body.getReader !== 'function') return 'no body stream';
    const reader = body.getReader();
    const chunks = [];
    for (;;) { const r = await reader.read(); if (r.done) break; chunks.push(Buffer.from(r.value)); }
    return Buffer.concat(chunks).toString() + ' locked=' + body.locked;
  });

  await namedThen('request-text', async () => {
    const request = new Request('https://example.com/', { method: 'POST', body: 'sent' });
    return await request.text();
  });

  await namedThen('request-clone', async () => {
    const request = new Request('https://example.com/', { method: 'POST', body: 'twice' });
    const copy = request.clone();
    return (await request.text()) + '|' + (await copy.text());
  });

  // A `data:` URL is a real fetch with no HTTP status line — and it is how a wasm module travels
  // inside a bundle, which is exactly how ink loads its layout engine. node answers 200 with the
  // media type from the URL; answering 0 says "no response", which reads as a failed fetch.
  await namedThen('fetch-a-data-url', async () => {
    const response = await fetch('data:application/octet-stream;base64,AGFzbQEAAAA=');
    const bytes = await response.arrayBuffer();
    return response.status + ' ok=' + response.ok
      + ' type=' + response.headers.get('content-type') + ' bytes=' + bytes.byteLength;
  });

  await namedThen('fetch-a-data-url-of-text', async () => {
    const response = await fetch('data:text/plain,hello%20there');
    return response.status + ' ' + JSON.stringify(await response.text());
  });

  await namedThen('blob-text', async () => {
    const blob = new Blob(['hello ', 'blob']);
    return (await blob.text()) + ' sliced=' + (await blob.slice(0, 5).text());
  });

  await namedThen('response-blob', async () => {
    const response = new Response('as a blob');
    if (typeof response.blob !== 'function') return 'no blob()';
    const blob = await response.blob();
    return blob.size + ' ' + (await blob.text());
  });
}

asyncScenarios().then(() => line('done', 'yes'),
                      (error) => line('done', 'FAILED ' + show(error)));
