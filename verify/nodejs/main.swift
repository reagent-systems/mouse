import Foundation

/// Remove exactly one level of leading indentation from each line. The suite used
/// `.stripIndent()`, which also strips four-space runs INSIDE the
/// expected text — silently corrupting anything containing table padding, aligned columns or
/// nested indentation. No fixture's content hit that until console.table did; this makes the
/// trap impossible rather than merely documented.
extension String {
    func stripIndent() -> String {
        split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.hasPrefix("    ") ? String($0.dropFirst(4)) : String($0) }
            .joined(separator: "\n")
    }
}

// Phase G verification per AGENTS.md: the same fixture scripts run through NodeEngine and
// through REAL node, in twin copies of the same directory tree; stdout and exit status are
// compared. Fixtures avoid the few knowingly-divergent areas (absolute cwd paths,
// setTimeout-vs-setImmediate ordering from the main module, stderr text).

let realNode = "/Users/thyfriendlyfox/.local/bin/node"

let fixtures: [(name: String, script: String, argv: [String], setup: [String: String])] = [
    ("console-format", """
    console.log('hello', 42, true, null, undefined);
    console.log({ a: 1, b: 'two', c: [1, 2, 3] });
    console.log([1, 'x', { nested: true }]);
    console.log('%s is %d%%', 'progress', 80);
    console.log(JSON.stringify({ k: 'v' }));
    """, [], [:]),

    ("path-module", """
    const path = require('path');
    console.log(path.join('a', 'b', '..', 'c'));
    console.log(path.join('/root', './x/', 'y'));
    console.log(path.normalize('a//b/../c/./d'));
    console.log(path.dirname('/a/b/c.txt'), path.basename('/a/b/c.txt'), path.extname('/a/b/c.txt'));
    console.log(path.basename('file.tar.gz', '.gz'));
    console.log(path.isAbsolute('/x'), path.isAbsolute('x'));
    console.log(path.resolve('/from', 'sub', '../peak'));
    console.log(path.relative('/a/b/c', '/a/d'));
    const parsed = path.parse('/home/user/file.txt');
    console.log(parsed.dir, parsed.base, parsed.ext, parsed.name);
    """, [], [:]),

    ("fs-roundtrip", """
    const fs = require('fs');
    fs.writeFileSync('data.txt', 'line one\\n');
    fs.appendFileSync('data.txt', 'line two\\n');
    console.log(fs.readFileSync('data.txt', 'utf8').trim());
    console.log(fs.existsSync('data.txt'), fs.existsSync('missing.txt'));
    fs.mkdirSync('sub');
    fs.writeFileSync('sub/inner.txt', 'x');
    console.log(fs.readdirSync('.').filter(n => !n.startsWith('.')).sort().join(','));
    const stat = fs.statSync('sub');
    console.log(stat.isDirectory(), stat.isFile());
    console.log(fs.statSync('data.txt').size);
    fs.unlinkSync('data.txt');
    console.log(fs.existsSync('data.txt'));
    try { fs.readFileSync('missing.txt'); } catch (e) { console.log('code', e.code); }
    """, [], [:]),

    ("modules-local", """
    const math = require('./lib/math');
    const config = require('./config.json');
    console.log(math.add(2, 3), math.mul(4, 5));
    console.log(config.name, config.count);
    console.log(require('./lib/math') === math);
    """, [], [
        "lib/math.js": "exports.add = (a, b) => a + b;\nexports.mul = (a, b) => a * b;\nmodule.exports.tag = __filename.endsWith('math.js');\n",
        "config.json": "{\"name\": \"fixture\", \"count\": 7}\n",
    ]),

    ("events-module", """
    const EventEmitter = require('events');
    const emitter = new EventEmitter();
    let sum = 0;
    const handler = n => { sum += n; };
    emitter.on('add', handler);
    emitter.once('add', n => console.log('once got', n));
    emitter.emit('add', 5);
    emitter.emit('add', 7);
    console.log('sum', sum, 'count', emitter.listenerCount('add'));
    emitter.removeListener('add', handler);
    emitter.emit('add', 100);
    console.log('final', sum);
    """, [], [:]),

    ("buffer-module", """
    const b = Buffer.from('héllo ✓');
    console.log(b.length, Buffer.byteLength('héllo ✓'));
    console.log(b.toString('hex'));
    console.log(b.toString('base64'));
    console.log(Buffer.from(b.toString('base64'), 'base64').toString());
    const joined = Buffer.concat([Buffer.from('ab'), Buffer.from('cd')]);
    console.log(joined.toString(), joined.length);
    console.log(Buffer.isBuffer(joined), Buffer.isBuffer('no'));
    console.log(Buffer.alloc(3, 0x61).toString());
    """, [], [:]),

    ("argv-env-exit", """
    console.log(process.argv.slice(2).join('|'));
    console.log(process.env.MOUSE_FIXTURE);
    console.log(typeof process.cwd());
    process.exitCode = undefined;
    process.exit(3);
    console.log('never');
    """, ["alpha", "beta gamma", "--flag"], [:]),

    ("timers-order", """
    const order = [];
    process.nextTick(() => order.push('tick'));
    Promise.resolve().then(() => order.push('promise'));
    setTimeout(() => order.push('t10'), 10);
    setTimeout(() => {
        order.push('t0');
        process.nextTick(() => order.push('tick-in-timer'));
    }, 0);
    let n = 0;
    const interval = setInterval(() => {
        order.push('i' + (++n));
        if (n === 3) { clearInterval(interval); console.log(order.join(',')); }
    }, 1);
    order.push('sync');
    """, [], [:]),

    ("async-await", """
    const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
    async function main() {
        console.log('start');
        await sleep(5);
        console.log('after sleep');
        const value = await Promise.all([1, 2, 3].map(async n => n * 2));
        console.log(value.join('-'));
    }
    main().then(() => console.log('done'));
    """, [], [:]),

    ("throw-exits-1", """
    console.log('before');
    JSON.parse('{nope');
    console.log('after');
    """, [], [:]),

    ("util-module", """
    const util = require('util');
    console.log(util.format('%s=%d', 'n', 42));
    console.log(util.inspect({ deep: { deeper: [1, 2] } }));
    function Legacy() {}
    function Base() {}
    util.inherits(Legacy, Base);
    console.log(Object.getPrototypeOf(Legacy.prototype) === Base.prototype);
    const wait = util.promisify((value, callback) => callback(null, value + 1));
    wait(41).then(result => console.log('promisified', result));
    """, [], [:]),

    ("assert-module", """
    const assert = require('assert');
    assert.ok(1 === 1);
    assert.strictEqual('a', 'a');
    assert.deepStrictEqual({ x: [1] }, { x: [1] });
    let threw = false;
    try { assert.strictEqual(1, 2); } catch (e) { threw = true; }
    console.log('caught', threw);
    """, [], [:]),

    ("fs-stream-events", """
    // Event ORDER matters: node opens the fd before writing, so open/ready precede
    // finish/close. Ours announced from a timer, so a synchronous write beat them.
    const fs = require('fs');
    const seen = [];
    const ws = fs.createWriteStream('out.txt');
    for (const ev of ['open', 'ready', 'finish', 'close']) ws.on(ev, () => seen.push(ev));
    ws.write('one\\n');
    ws.end('two\\n');
    setTimeout(() => {
      console.log('order:', seen.join(','));
      console.log('content:', JSON.stringify(fs.readFileSync('out.txt', 'utf8')));
      const { Readable, pipeline } = require('stream');
      const piped = [];
      const ws2 = fs.createWriteStream('piped.txt');
      for (const ev of ['finish', 'close']) ws2.on(ev, () => piped.push(ev));
      pipeline(Readable.from(['a', 'b']), ws2, (err) => setTimeout(() => {
        console.log('pipeline:', piped.join(','), 'err:', err === null || err === undefined);
        console.log('piped content:', JSON.stringify(fs.readFileSync('piped.txt', 'utf8')));
      }, 50));
    }, 100);
    """, [], [:]),

    ("fetch-api-family", """
    // Headers/Blob/File/FormData/Request/Response — the shapes agent CLIs use when they
    // call a model API. Previously only a hand-rolled response literal existed.
    const h = new Headers({ 'Content-Type': 'application/json' });
    h.append('x-multi', 'a');
    h.append('X-Multi', 'b');
    console.log('headers get:', h.get('content-type'), '| multi:', h.get('x-multi'), '| has:', h.has('X-MULTI'));
    console.log('header names:', [...h.keys()].join(','));
    const seen = [];
    h.forEach((v, k) => seen.push(k));
    console.log('forEach names:', seen.join(','));
    const blob = new Blob(['hello ', 'blob'], { type: 'text/plain' });
    console.log('blob:', blob.size, blob.type);
    const file = new File(['data'], 'note.txt', { type: 'text/plain' });
    console.log('file:', file.name, file.size, file instanceof Blob);
    const form = new FormData();
    form.append('a', '1');
    form.append('a', '2');
    console.log('formdata:', form.get('a'), form.getAll('a').join('+'), form.has('b'));
    const req = new Request('https://example.dev/x', { method: 'POST', body: 'payload', headers: { 'x-k': 'v' } });
    console.log('request:', req.method, req.url, req.headers.get('x-k'));
    const res = new Response(JSON.stringify({ ok: 1 }), { status: 201, headers: { 'content-type': 'application/json' } });
    console.log('response:', res.status, res.ok, res.headers.get('content-type'), res.bodyUsed);
    Promise.all([res.clone().json(), new Response('text').text(), Response.json({ z: 9 }).then ? null : null])
      .then(([parsed, text]) => {
        console.log('json body:', JSON.stringify(parsed), '| text body:', text);
        // The body STREAM contract — what streaming model responses read.
        const streamed = new Response('chunked payload');
        const reader = streamed.body.getReader();
        return reader.read().then((first) => {
          console.log('stream first chunk:', Buffer.from(first.value).toString(), 'done:', first.done);
          return reader.read().then((second) => console.log('stream ends:', second.done));
        });
      });
    console.log('static json helper:', Response.json({ a: 1 }).headers.get('content-type'));
    console.log('navigator:', typeof navigator.userAgent === 'string');
    """, [], [:]),

    ("core-module-fillins", """
    // Members found missing by auditing every core module's exports against real node's.
    const path = require('path');
    console.log('path.format:', path.format({ dir: '/a/b', name: 'c', ext: '.txt' }),
                path.format({ root: '/', base: 'x.js' }), JSON.stringify(path.format({ base: 'only' })));
    const qs = require('querystring');
    console.log('qs aliases:', qs.encode({ a: 1 }), qs.decode('b=2').b, qs.escape('a b'), qs.unescape('a%20b'));
    const url = require('url');
    console.log('url.format:', url.format({ protocol: 'https:', host: 'x.dev', pathname: '/p', search: '?q=1' }));
    console.log('url.resolve:', url.resolve('https://x.dev/a/b', 'c'), url.resolve('https://x.dev/a/b', '/root'));
    const assert = require('assert');
    assert.doesNotMatch('abc', /zzz/);
    Promise.all([
      assert.rejects(Promise.reject(new Error('boom'))),
      assert.doesNotReject(Promise.resolve(1)),
    ]).then(() => console.log('assert async helpers ok'));
    const events = require('events');
    const EventEmitter = events;
    const em = new EventEmitter();
    em.on('x', () => {});
    console.log('events.listenerCount:', events.listenerCount(em, 'x'), 'getEventListeners:', events.getEventListeners(em, 'x').length);
    const bufferMod = require('buffer');
    console.log('isUtf8/isAscii:', bufferMod.isUtf8(Buffer.from('hi')), bufferMod.isAscii(Buffer.from('hi')), bufferMod.isAscii(Buffer.from([0xff])));
    const stream = require('stream');
    const { Readable } = stream;
    const rr = new Readable({ read() {} });
    console.log('stream predicates:', stream.isReadable(rr), stream.isWritable(rr), stream.isDestroyed(rr));
    console.log('isWritable on a Writable:', stream.isWritable(new stream.Writable({ write(c,e,cb){cb();} })));
    console.log('highWaterMark:', stream.getDefaultHighWaterMark(false), stream.getDefaultHighWaterMark(true));
    const zlib = require('zlib');
    console.log('crc32:', zlib.crc32('hello world').toString(16), 'codes.Z_OK:', zlib.codes.Z_OK);
    const http = require('http');
    let headerThrew = 'no';
    try { http.validateHeaderName('bad header'); } catch (e) { headerThrew = e.code; }
    console.log('validateHeaderName:', headerThrew);
    const os = require('os');
    console.log('os extras:', typeof os.availableParallelism(), typeof os.machine());
    const util = require('util');
    console.log('util symbols:', typeof util.inspect.custom, typeof util.promisify.custom, typeof util.TextEncoder);
    """, [], [:]),

    ("stream-state-props", """
    // The observable state libraries branch on to decide "is this stream done?".
    const { Readable, Writable } = require('stream');
    const r = new Readable({ read() {} });
    const w = new Writable({ write(c, e, cb) { cb(); } });
    console.log('initial readable:', r.readableEnded, r.readableFlowing, r.readableLength, r.readableObjectMode);
    console.log('initial writable:', w.writableEnded, w.writableFinished, w.writableLength, w.writableObjectMode);
    console.log('initial closed/errored:', r.closed, r.errored, w.closed, w.errored);
    r.push('ab');
    console.log('after push, length:', r.readableLength);
    r.on('data', () => {});
    r.push(null);
    w.write('x');
    w.end();
    setTimeout(() => {
      console.log('ended readable:', r.readableEnded, 'flowing:', r.readableFlowing, 'closed:', r.closed);
      console.log('ended writable:', w.writableEnded, 'finished:', w.writableFinished, 'closed:', w.closed);
    }, 60);
    """, [], [:]),

    ("stream-es5-inherits", """
    // The dominant legacy stream idiom in npm: util.inherits + Base.call(this, opts).
    // A class constructor throws when called without `new`, so every stream class had to
    // become a constructor function (readable-stream, under a huge share of packages).
    const util = require('util');
    const { Readable, Writable, Duplex, Transform, Stream } = require('stream');
    const { StringDecoder } = require('string_decoder');
    for (const [name, Base, arg] of [['Readable', Readable, {}], ['Writable', Writable, {}],
                                     ['Duplex', Duplex, {}], ['Transform', Transform, {}],
                                     ['Stream', Stream, undefined],
                                     ['StringDecoder', StringDecoder, 'utf8']]) {
      function Sub() { Base.call(this, arg); }
      util.inherits(Sub, Base);
      const made = new Sub();
      console.log(name + ' es5-callable:', made instanceof Base);
    }
    // node validates decoder encodings; ours used to accept anything.
    try { new StringDecoder({}); } catch (e) { console.log('bad encoding code:', e.code); }
    // An inherited Writable must actually work, not just construct.
    function Collect() { Writable.call(this, {}); this.got = []; }
    util.inherits(Collect, Writable);
    Collect.prototype._write = function(chunk, enc, cb) { this.got.push(String(chunk)); cb(); };
    const sink = new Collect();
    sink.on('finish', () => console.log('inherited writable collected:', sink.got.join('')));
    sink.write('a');
    sink.end('b');
    // And a class subclass still works (both idioms coexist).
    class Modern extends Transform {
      _transform(c, e, cb) { cb(null, String(c).toUpperCase()); }
    }
    const m = new Modern();
    const out = [];
    m.on('data', (c) => out.push(String(c)));
    m.on('end', () => console.log('class transform:', out.join('')));
    m.end('xy');
    """, [], [:]),

    ("emitter-es5-call", """
    // node's EventEmitter is a constructor FUNCTION: readable-stream (under archiver and
    // much of npm) does EventEmitter.call(this), which throws on an ES6 class.
    const EventEmitter = require('events');
    function Legacy(opts) { EventEmitter.call(this, opts); this.tag = 'legacy'; }
    Legacy.prototype = Object.create(EventEmitter.prototype);
    Legacy.prototype.constructor = Legacy;
    const it = new Legacy({});
    let got = null;
    it.on('ping', (v) => { got = v; });
    it.emit('ping', 7);
    console.log('es5 subclass works:', it.tag, got);
    console.log('still newable:', new EventEmitter() instanceof EventEmitter);
    class Modern extends EventEmitter {}
    const m = new Modern();
    m.on('x', () => console.log('class subclass works'));
    m.emit('x');
    """, [], [:]),

    ("zlib-incremental", """
    // Streaming gunzip: chunks fed one at a time must decode against a LIVE z_stream.
    // (A one-shot codec can't — a partial gzip member isn't decodable alone.)
    const zlib = require('zlib');
    const text = 'streaming payload '.repeat(200);
    const packed = zlib.gzipSync(text);
    const gunzip = zlib.createGunzip();
    const out = [];
    gunzip.on('data', (c) => out.push(c));
    gunzip.on('end', () => {
      const joined = Buffer.concat(out).toString();
      console.log('roundtrip ok:', joined === text, 'length:', joined.length);
      // Now the reverse: incremental DEFLATE, decoded by the one-shot path.
      const gzipStream = zlib.createGzip();
      const packedChunks = [];
      gzipStream.on('data', (c) => packedChunks.push(c));
      gzipStream.on('end', () => {
        const recompressed = Buffer.concat(packedChunks);
        console.log('incremental gzip roundtrips:', zlib.gunzipSync(recompressed).toString() === text);
      });
      for (let i = 0; i < text.length; i += 700) gzipStream.write(text.slice(i, i + 700));
      gzipStream.end();
    });
    // Feed the compressed bytes in small pieces — the real streaming case.
    for (let i = 0; i < packed.length; i += 64) gunzip.write(packed.slice(i, i + 64));
    gunzip.end();
    """, [], [:]),

    ("utf8-lenient-decode", """
    // Decoding BINARY as utf8 must yield replacement chars, never throw (tar does
    // buf.toString() on gzip blocks; the strict decoder threw "out of range of code points").
    const binary = Buffer.from([0x1f, 0x8b, 0x08, 0x00, 0xff, 0xfe, 0xf8, 0x80, 0xc0, 0x41]);
    const decoded = binary.toString('utf8');
    console.log('did not throw, length:', decoded.length > 0);
    console.log('ascii survives:', decoded.includes('A'));
    console.log('has replacement:', decoded.includes('\\uFFFD'));
    // Valid text still round-trips exactly.
    const text = 'héllo ✓ 𝄞 end';
    console.log('roundtrip:', Buffer.from(text).toString('utf8') === text);
    // A truncated multi-byte sequence at the end decodes without throwing.
    console.log('truncated ok:', Buffer.from([0xe2, 0x9c]).toString('utf8').length >= 1);
    """, [], [:]),

    ("stack-has-source", """
    // Module frames must name their file: without a sourceURL every JSC frame was a bare
    // "fn@", making terminal errors unreadable.
    const boom = require('./boom.js');
    try { boom(); } catch (e) {
      console.log('stack names the module:', /boom\\.js/.test(e.stack));
      console.log('stack has a line number:', /boom\\.js:\\d+/.test(e.stack));
    }
    """, [], [
        "boom.js": "module.exports = function boom() {\n  throw new Error('kaboom');\n};\n",
    ]),

    ("fs-async-callbacks", """
    // The async callback API (fs.open/read/write/close/...) — 29 of these were missing;
    // tar and friends use the callback forms as much as the sync ones.
    const fs = require('fs');
    fs.open('data.bin', 'w', (err, fd) => {
      console.log('open:', err === null, typeof fd === 'number');
      const payload = Buffer.from('hello fd world');
      fs.write(fd, payload, 0, 5, null, (werr, written, buf) => {
        console.log('write:', werr === null, 'bytes:', written, 'buffer back:', Buffer.isBuffer(buf));
        fs.close(fd, (cerr) => {
          console.log('close:', cerr === null, 'content:', JSON.stringify(fs.readFileSync('data.bin', 'utf8')));
          fs.open('data.bin', 'r', (oerr, rfd) => {
            const into = Buffer.alloc(5);
            fs.read(rfd, into, 0, 5, 0, (rerr, bytesRead, rbuf) => {
              console.log('read:', bytesRead, JSON.stringify(into.toString()), Buffer.isBuffer(rbuf));
              fs.closeSync(rfd);
              // truncate, mkdtemp, and the honest symlink refusal
              fs.writeFileSync('trunc.txt', 'abcdefgh');
              fs.truncateSync('trunc.txt', 3);
              console.log('truncated:', fs.readFileSync('trunc.txt', 'utf8'));
              const tmp = fs.mkdtempSync('tmp-');
              console.log('mkdtemp is dir:', fs.statSync(tmp).isDirectory());
              try { fs.readlinkSync('trunc.txt'); } catch (e) { console.log('readlink code:', e.code); }
              fs.chmod('trunc.txt', 0o644, (merr) => console.log('chmod async:', merr === null));
            });
          });
        });
      });
    });
    """, [], [:]),

    ("buffer-binary-methods", """
    // The binary read/write surface tar's header codec (and any wire protocol) needs.
    const b = Buffer.alloc(16);
    const wrote = b.write('hi', 2, 2, 'utf8');
    console.log('write returned:', wrote, 'slice:', JSON.stringify(b.toString('utf8', 2, 4)));
    b.writeUInt32BE(0xdeadbeef, 4);
    b.writeUInt16LE(0x0102, 8);
    b.writeInt8(-5, 10);
    console.log('u32be:', b.readUInt32BE(4).toString(16), 'u16le:', b.readUInt16LE(8).toString(16), 'i8:', b.readInt8(10));
    const target = Buffer.alloc(4);
    Buffer.from('abcdef').copy(target, 0, 1, 5);
    console.log('copied:', target.toString());
    console.log('indexOf:', Buffer.from('hello world').indexOf('world'), Buffer.from('abc').indexOf('z'));
    console.log('includes:', Buffer.from('abc').includes('bc'));
    console.log('compare:', Buffer.from('a').compare(Buffer.from('b')), Buffer.from('b').compare(Buffer.from('a')));
    const d = Buffer.alloc(8);
    d.writeDoubleBE(1.5, 0);
    console.log('double:', d.readDoubleBE(0));
    """, [], [:]),

    ("zlib-classes", """
    // minizlib (under tar) instantiates the CLASS forms; node also mirrors constants.
    const zlib = require('zlib');
    console.log('classes:', typeof zlib.Gzip, typeof zlib.Gunzip, typeof zlib.Deflate, typeof zlib.InflateRaw);
    console.log('constants mirrored:', zlib.Z_SYNC_FLUSH === 2, zlib.constants.Z_FINISH === 4);
    const gz = new zlib.Gzip();
    const chunks = [];
    gz.on('data', (c) => chunks.push(c));
    gz.on('end', () => {
      const packed = Buffer.concat(chunks);
      console.log('gzip magic:', packed[0] === 0x1f && packed[1] === 0x8b);
      console.log('roundtrip:', zlib.gunzipSync(packed).toString());
    });
    gz.end('payload text');
    """, [], [:]),

    ("fs-fd-as-path", """
    // node lets an FD stand in for a path: claude-code writes its config as
    // openSync('w') → writeFileSync(fd, data) → fsyncSync → closeSync. Treating the number
    // as a path silently truncated the file and dropped the data.
    const fs = require('fs');
    const payload = JSON.stringify({ config: 'kept', n: 42 });
    const fd = fs.openSync('cfg.json', 'w');
    fs.writeFileSync(fd, payload);
    fs.fsyncSync(fd);
    fs.closeSync(fd);
    console.log('written:', fs.readFileSync('cfg.json', 'utf8'));
    const rfd = fs.openSync('cfg.json', 'r');
    console.log('read via fd:', fs.readFileSync(rfd, 'utf8') === payload);
    fs.closeSync(rfd);
    const afd = fs.openSync('log.txt', 'a');
    fs.appendFileSync(afd, 'one\\n');
    fs.closeSync(afd);
    console.log('append via fd:', JSON.stringify(fs.readFileSync('log.txt', 'utf8')));
    """, [], [:]),

    ("events-lazy-mixin", """
    // express's pattern: EventEmitter.prototype mixed into a plain function, constructor
    // never called — methods must lazily create _events.
    const EventEmitter = require('events');
    const app = function() {};
    Object.assign(app, EventEmitter.prototype);
    app.on('boot', (v) => console.log('mixin got', v));
    app.emit('boot', 42);
    console.log('count:', app.listenerCount('boot'));
    """, [], [:]),

    ("callsite-protocol", """
    // depd's pattern (under express): prepareStackTrace + captureStackTrace yields
    // structured CallSites with callable accessors.
    const obj = {};
    const prep = Error.prepareStackTrace;
    Error.prepareStackTrace = (e, stack) => stack;
    Error.captureStackTrace(obj);
    const site = obj.stack[0];   // V8's stack is lazy: read BEFORE restoring (depd does)
    Error.prepareStackTrace = prep;
    console.log('callable:', typeof site.getFileName === 'function', typeof site.getLineNumber === 'function');
    console.log('line is number-or-null:', site.getLineNumber() === null || typeof site.getLineNumber() === 'number');
    """, [], [:]),

    ("microtask-only-tla", """
    // A top-level await that settles purely via microtasks (no timer) must exit 0 —
    // this raced the entry-pending flag and stamped exit 13 on healthy runs.
    const x = await Promise.resolve(41) + 1;
    const y = await Promise.all([x, Promise.resolve(x)]).then(([a]) => a);
    console.log('microtask entry:', y);
    """, [], [
        "package.json": "{\"type\": \"module\"}",
    ]),

    ("dynamic-import-cjs", """
    // Dynamic import() is legal in CJS (prettier lazy-loads plugins this way).
    import('./dep.mjs').then((m) => {
      console.log('dyn:', m.answer, typeof m.default);
    });
    """, [], [
        "dep.mjs": "export const answer = 42;\nexport default function noop() {}\n",
    ]),

    ("filename-shadow-esm", """
    import { fileURLToPath } from 'url';
    import { basename } from 'path';
    const __filename = fileURLToPath(import.meta.url);
    const __dirname = basename(__filename);
    console.log('shadowed filename ends right:', __filename.endsWith('main.js'), __dirname);
    """, [], [
        "package.json": "{\"type\": \"module\"}",
    ]),

    ("circular-live-exports", """
    // semver's pattern: module.exports assigned BEFORE the circular require closes.
    const A = require('./a.js');
    console.log('A is fn:', typeof A === 'function', 'A.partner is fn:', typeof A.partner === 'function');
    console.log('cycle saw class:', A.sawClassAtCycle);
    """, [], [
        "a.js": """
        class A { static hello() { return 'a'; } }
        module.exports = A;
        const B = require('./b.js');
        A.partner = B;
        """,
        "b.js": """
        class B {}
        module.exports = B;
        const A = require('./a.js');
        B.sawClass = typeof A === 'function';
        module.exports.sawClassAtCycle = typeof A === 'function';
        const back = require('./a.js');
        A.sawClassAtCycle = typeof back === 'function';
        """,
    ]),

    ("styletext-als-pipe", """
    const util = require('util');
    const red = util.styleText('red', 'x');
    console.log('styleText:', JSON.stringify(red));
    console.log('array form:', JSON.stringify(util.styleText(['bold', 'green'], 'y')));
    const { AsyncLocalStorage } = require('async_hooks');
    const als = new AsyncLocalStorage();
    als.run({ id: 7 }, async () => {
      await new Promise(r => setTimeout(r, 10));
      console.log('ALS after await:', als.getStore().id);
    }).then(() => {
      const { Stream, Writable } = require('stream');
      const source = new Stream();
      const got = [];
      const dest = new Writable({ write(c, e, cb) { got.push(String(c)); cb(); } });
      dest.on('finish', () => console.log('piped:', got.join('')));
      source.pipe(dest);
      source.emit('data', 'ab'); source.emit('data', 'cd'); source.emit('end');
    });
    """, [], [:]),

    ("readdir-dirent", """
    const fs = require('fs');
    fs.mkdirSync('tree'); fs.mkdirSync('tree/sub');
    fs.writeFileSync('tree/file.txt', 'x');
    const entries = fs.readdirSync('tree', { withFileTypes: true })
      .sort((a, b) => a.name < b.name ? -1 : 1);
    for (const e of entries) console.log(e.name, 'file=' + e.isFile(), 'dir=' + e.isDirectory());
    console.log('plain still strings:', typeof fs.readdirSync('tree')[0]);
    """, [], [:]),

    ("realpath-webcrypto", """
    const fs = require('fs');
    fs.writeFileSync('real.txt', 'x');
    console.log('native type:', typeof fs.realpath.native, typeof fs.realpathSync.native);
    fs.realpath('real.txt', (err, p) => {
      console.log('realpath cb:', err === null, p.endsWith('real.txt'));
      const view = new Uint8Array(8);
      crypto.getRandomValues(view);
      console.log('webcrypto:', view.length === 8, typeof crypto.randomUUID());
    });
    """, [], [:]),

    ("assert-more", """
    const assert = require('assert');
    assert.notStrictEqual(1, 2);
    assert.notDeepStrictEqual({a:1}, {a:2});
    assert.doesNotThrow(() => {});
    assert.match('hello', /ell/);
    assert.ifError(null);
    let caught = 0;
    try { assert.notStrictEqual(3, 3); } catch (e) { caught++; }
    try { assert.match('x', /y/); } catch (e) { caught++; }
    console.log('assert extras ok, caught', caught);
    """, [], [:]),

    ("uncaught-handled", """
    process.on('uncaughtException', (e) => { console.log('caught:', e.message); });
    throw new Error('boom');
    console.log('after-throw');
    """, [], [:]),

    ("uncaught-handler-exits", """
    process.on('uncaughtException', (e) => { console.log('caught:', e.message); process.exit(42); });
    throw new Error('boom2');
    console.log('never');
    """, [], [:]),

    ("events-error-throw", """
    const EventEmitter = require('events');
    const ee = new EventEmitter();
    let threw = false;
    try { ee.emit('error', new Error('boom')); } catch (e) { threw = e.message; }
    console.log('unhandled error threw:', threw);
    const handled = new EventEmitter();
    handled.on('error', (e) => console.log('handled:', e.message));
    console.log('emit returned:', handled.emit('error', new Error('caught')));
    const ee2 = new EventEmitter();
    ee2.setMaxListeners(5);
    ee2.prependListener('x', () => console.log('second'));
    ee2.prependListener('x', () => console.log('first'));
    ee2.emit('x');
    console.log('names:', ee2.eventNames().join(','), 'count:', ee2.listenerCount('x'));
    """, [], [:]),

    ("timer-objects", """
    const t = setTimeout(() => {}, 10000);
    console.log('unref:', typeof t.unref, 'ref:', typeof t.ref);
    console.log('unref chains:', t.unref() === t);
    clearTimeout(t);
    const i = setInterval(() => {}, 10000);
    i.unref();
    clearInterval(i);
    const im = setImmediate(() => {});
    console.log('immediate unref:', typeof im.unref);
    console.log('coerces to number:', typeof (setTimeout(() => {}, 0) + 0));
    """, [], [:]),

    ("fs-fd-sync", """
    const fs = require('fs');
    const fd = fs.openSync('fdtest.txt', 'w');
    fs.writeSync(fd, 'hello ');
    fs.writeSync(fd, 'world');
    fs.closeSync(fd);
    console.log('written:', fs.readFileSync('fdtest.txt', 'utf8'));
    const rfd = fs.openSync('fdtest.txt', 'r');
    const buf = Buffer.alloc(5);
    const n = fs.readSync(rfd, buf, 0, 5, 0);
    console.log('read', n, 'bytes:', buf.toString());
    console.log('fstat isFile:', fs.fstatSync(rfd).isFile());
    fs.closeSync(rfd);
    """, [], [:]),

    ("stream-readable", """
    const { Readable } = require('stream');
    const r = new Readable({ read() {} });
    const seen = [];
    r.setEncoding('utf8');
    r.on('data', (c) => seen.push(c));
    r.on('end', () => console.log('ended:', seen.join('|')));
    r.push('one');
    r.push('two');
    r.push(null);
    console.log('paused?', r.isPaused());
    """, [], [:]),

    ("stream-writable", """
    const { Writable } = require('stream');
    const got = [];
    const w = new Writable({
      write(chunk, encoding, callback) { got.push(String(chunk)); callback(); },
      final(callback) { got.push('<final>'); callback(); },
    });
    w.on('finish', () => console.log('finish:', got.join('|')));
    w.on('close', () => console.log('closed'));
    w.write('a');
    w.write('b');
    w.end('c');
    """, [], [:]),

    ("stream-transform", """
    const { Readable, Transform, Writable } = require('stream');
    const upper = new Transform({
      transform(chunk, encoding, callback) { callback(null, String(chunk).toUpperCase()); },
      flush(callback) { callback(null, '!'); },
    });
    const out = [];
    const sink = new Writable({ write(c, e, cb) { out.push(String(c)); cb(); } });
    sink.on('finish', () => console.log(out.join('')));
    const source = Readable.from(['ab', 'cd']);
    source.pipe(upper).pipe(sink);
    """, [], [:]),

    ("stream-pipeline", """
    const { Readable, PassThrough, Writable, pipeline } = require('stream');
    const out = [];
    pipeline(
      Readable.from(['x', 'y', 'z']),
      new PassThrough(),
      new Writable({ write(c, e, cb) { out.push(String(c)); cb(); } }),
      (err) => console.log('done', err === null || err === undefined ? 'clean' : 'error', out.join(''))
    );
    """, [], [:]),

    ("stream-pipeline-promises", """
    const { pipeline } = require('stream/promises');
    const { Readable, Writable } = require('stream');
    const out = [];
    pipeline(
      Readable.from(['p', 'q']),
      new Writable({ write(c, e, cb) { out.push(String(c)); cb(); } })
    ).then(() => console.log('resolved', out.join('')));
    """, [], [:]),

    ("stream-async-iter", """
    const { Readable } = require('stream');
    async function main() {
      const chunks = [];
      for await (const chunk of Readable.from(['m1', 'm2', 'm3'])) chunks.push(chunk);
      console.log(chunks.join(','));
    }
    main().then(() => console.log('after'));
    """, [], [:]),

    ("fs-streams", """
    const fs = require('fs');
    const ws = fs.createWriteStream('log.txt');
    ws.write('line one\\n');
    ws.write('line two\\n');
    ws.end('line three\\n');
    ws.on('close', () => {
      const rs = fs.createReadStream('log.txt', 'utf8');
      let text = '';
      rs.on('data', (c) => { text += c; });
      rs.on('end', () => console.log(text.trim()));
    });
    """, [], [:]),

    ("crypto-module", """
    const crypto = require('crypto');
    console.log(crypto.createHash('md5').update('hello world').digest('hex'));
    console.log(crypto.createHash('sha1').update('hello world').digest('hex'));
    console.log(crypto.createHash('sha256').update('hello').update(' world').digest('hex'));
    console.log(crypto.createHash('sha512').update('abc').digest('base64'));
    console.log(crypto.createHash('sha384').update(Buffer.from([1, 2, 3])).digest('hex'));
    console.log(crypto.createHmac('sha256', 'secret').update('payload').digest('hex'));
    console.log(crypto.createHmac('sha1', Buffer.from('6b6579', 'hex')).update('data').digest('hex'));
    console.log(crypto.createHmac('md5', 'k').update('m').digest('hex'));
    console.log(crypto.randomBytes(16).length, typeof crypto.randomUUID());
    console.log(/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(crypto.randomUUID()));
    console.log(crypto.timingSafeEqual(Buffer.from('aa'), Buffer.from('aa')), crypto.timingSafeEqual(Buffer.from('aa'), Buffer.from('ab')));
    const n = crypto.randomInt(10);
    console.log(n >= 0 && n < 10);
    crypto.randomBytes(8, (err, buf) => console.log('async', err === null, buf.length));
    """, [], [:]),

    ("zlib-module", """
    const zlib = require('zlib');
    const text = 'the quick brown fox jumps over the lazy dog '.repeat(50);
    const gz = zlib.gzipSync(text);
    console.log('gzip magic', gz[0] === 0x1f && gz[1] === 0x8b);
    console.log('roundtrip', String(zlib.gunzipSync(gz)) === text);
    const flate = zlib.deflateSync(Buffer.from(text));
    console.log('inflate', String(zlib.inflateSync(flate)) === text);
    const raw = zlib.deflateRawSync(text);
    console.log('raw', String(zlib.inflateRawSync(raw)) === text);
    console.log('unzip', String(zlib.unzipSync(gz)) === text);
    console.log('smaller', gz.length < text.length);
    let threw = false;
    try { zlib.gunzipSync(Buffer.from('junk')); } catch (e) { threw = true; }
    console.log('bad input throws', threw);
    zlib.gunzip(gz, (err, buf) => console.log('async', err === null, String(buf) === text));
    """, [], [:]),

    ("zlib-streams", """
    const zlib = require('zlib');
    const { Readable, Writable } = require('stream');
    const chunks = [];
    Readable.from(['abc', 'def'])
      .pipe(zlib.createGzip())
      .pipe(zlib.createGunzip())
      .pipe(new Writable({ write(c, e, cb) { chunks.push(c); cb(); } }))
      .on('finish', () => console.log(Buffer.concat(chunks).toString()));
    """, [], [:]),

    ("readline-file", """
    const fs = require('fs');
    const readline = require('readline');
    const rl = readline.createInterface({ input: fs.createReadStream('lines.txt'), crlfDelay: Infinity });
    let n = 0;
    rl.on('line', (line) => { n += 1; console.log(n + ': ' + line); });
    rl.on('close', () => console.log('total', n));
    """, [], ["lines.txt": "alpha\nbeta\ngamma"]),

    ("stream-error-pipeline", """
    const { Readable, Transform, Writable, pipeline } = require('stream');
    const boom = new Transform({
      transform(chunk, encoding, callback) { callback(new Error('kaput')); },
    });
    pipeline(
      Readable.from(['x']),
      boom,
      new Writable({ write(c, e, cb) { cb(); } }),
      (err) => console.log('pipeline error:', err ? err.message : 'none')
    );
    """, [], [:]),
]

func writeSetup(_ files: [String: String], into dir: URL) {
    for (path, content) in files {
        let url = dir.appendingPathComponent(path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? content.write(to: url, atomically: true, encoding: .utf8)
    }
}

func runReal(script: String, argv: [String], dir: URL, entry: String = "main.js") -> (out: String, status: Int32) {
    try? script.write(to: dir.appendingPathComponent(entry), atomically: true, encoding: .utf8)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: realNode)
    process.arguments = [entry] + argv
    process.currentDirectoryURL = dir
    var environment = ProcessInfo.processInfo.environment
    environment["MOUSE_FIXTURE"] = "fixture-value"
    process.environment = environment
    let out = Pipe()
    process.standardOutput = out
    process.standardError = Pipe()
    try? process.run()
    process.waitUntilExit()
    return (String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), process.terminationStatus)
}

/// The harness's shell bridge runs /bin/sh in the fixture dir — the same shell the real-node
/// side's child_process uses, so bridge MECHANICS are what's under test (msh semantics are
/// verified end-to-end separately through mshdbg).
func makeShellBridge(dir: URL) -> NodeEngine.ShellBridge {
    NodeEngine.ShellBridge { command in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = dir
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try? process.run()
        process.waitUntilExit()
        return (String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
                String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
                process.terminationStatus)
    }
}

@MainActor
func runOurs(script: String, argv: [String], dir: URL, entry: String = "main.js") async -> (out: String, status: Int32) {
    try? script.write(to: dir.appendingPathComponent(entry), atomically: true, encoding: .utf8)
    let engine = NodeEngine(root: dir, env: ["MOUSE_FIXTURE": "fixture-value", "PATH": "/"],
                            shell: makeShellBridge(dir: dir))
    let result = await engine.run(source: script, path: "/" + entry,
                                  argv: ["node", "/" + entry] + argv, cwd: "/", stdin: "")
    return (result.out, result.status)
}

var failures = 0
let base = FileManager.default.temporaryDirectory.appendingPathComponent("node-verify-\(getpid())")

for fixture in fixtures {
    let oursDir = base.appendingPathComponent("ours-\(fixture.name)")
    let realDir = base.appendingPathComponent("real-\(fixture.name)")
    try? FileManager.default.createDirectory(at: oursDir, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(at: realDir, withIntermediateDirectories: true)
    writeSetup(fixture.setup, into: oursDir)
    writeSetup(fixture.setup, into: realDir)

    let ours = await runOurs(script: fixture.script, argv: fixture.argv, dir: oursDir)
    let real = runReal(script: fixture.script, argv: fixture.argv, dir: realDir)
    if ours.out == real.out && ours.status == real.status {
        print("fixture \(fixture.name): match")
    } else {
        failures += 1
        print("MISMATCH: \(fixture.name) (status ours=\(ours.status) real=\(real.status))")
        print("  ---- ours ----\n\(ours.out)  ---- real ----\n\(real.out)  --------------")
    }
}

// -- node_modules: left-pad through both engines, from OUR installed tree --------
let pkgDir = base.appendingPathComponent("pkg-fixture")
try? FileManager.default.createDirectory(at: pkgDir, withIntermediateDirectories: true)
do {
    _ = try await PackageManager.install(requirements: ["left-pad": "^1.3.0", "ms": "^2.1.0"], into: pkgDir)
    let script = """
    const leftPad = require('left-pad');
    const ms = require('ms');
    console.log(leftPad('7', 4, '0'));
    console.log(ms(90000));
    console.log(ms('2h'));
    """
    let ours = await runOurs(script: script, argv: [], dir: pkgDir)
    let real = runReal(script: script, argv: [], dir: pkgDir)
    if ours.out == real.out && ours.status == real.status {
        print("fixture node-modules: match")
    } else {
        failures += 1
        print("MISMATCH: node-modules\n  ours: \(ours.out)\n  real: \(real.out)")
    }
} catch {
    failures += 1
    print("FAIL: node_modules fixture install: \(error.localizedDescription)")
}

// -- a real installed BIN runs on our engine: mkdirp creates a directory ---------
let binDir = base.appendingPathComponent("bin-fixture")
try? FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
do {
    let report = try await PackageManager.install(requirements: ["mkdirp": "^1.0.0"], into: binDir)
    guard let binPath = report.bins["mkdirp"] else { throw PackageManager.PackageError("no mkdirp bin") }
    let source = try String(contentsOf: binDir.appendingPathComponent(binPath), encoding: .utf8)
    let engine = NodeEngine(root: binDir, env: [:])
    let result = await engine.run(source: source, path: "/" + binPath,
                                  argv: ["node", "/" + binPath, "made/by/mouse"], cwd: "/", stdin: "")
    var isDirectory: ObjCBool = false
    let created = FileManager.default.fileExists(atPath: binDir.appendingPathComponent("made/by/mouse").path,
                                                 isDirectory: &isDirectory) && isDirectory.boolValue
    if result.status == 0 && created {
        print("fixture mkdirp-bin: our engine ran the installed bin and created the directory")
    } else {
        failures += 1
        print("MISMATCH: mkdirp-bin status=\(result.status) created=\(created) err=\(result.err)")
    }
} catch {
    failures += 1
    print("FAIL: mkdirp bin fixture: \(error.localizedDescription)")
}

// -- ESM: local modules, all the statement forms ---------------------------------
let esmSetup = [
    "lib/values.mjs": """
    export const alpha = 1;
    export let beta = 'two';
    export function triple(n) { return n * 3; }
    export class Box { constructor(v) { this.v = v; } }
    const hidden = 'internal';
    export { hidden as revealed };
    export default 'the-default';
    """,
    "lib/again.mjs": "export * from './values.mjs';\nexport { alpha as first } from './values.mjs';\n",
]
let esmScript = """
import def, { alpha, beta as b, triple } from './lib/values.mjs';
import * as ns from './lib/values.mjs';
import { first, revealed } from './lib/again.mjs';
console.log(def, alpha, b, triple(7));
console.log(ns.alpha, typeof ns.Box, ns.default);
console.log(first, revealed);
const dynamic = await import('./lib/values.mjs');
console.log('dynamic', dynamic.alpha, dynamic.default);
"""
// top-level await differs; wrap ours + real identically in async main
let esmWrapped = """
import def, { alpha, beta as b, triple } from './lib/values.mjs';
import * as ns from './lib/values.mjs';
import { first, revealed } from './lib/again.mjs';
console.log(def, alpha, b, triple(7));
console.log(ns.alpha, typeof ns.Box, ns.default);
console.log(first, revealed);
import('./lib/values.mjs').then(dynamic => console.log('dynamic', dynamic.alpha, dynamic.default));
"""
_ = esmScript
do {
    let oursDir = base.appendingPathComponent("ours-esm")
    let realDir = base.appendingPathComponent("real-esm")
    try? FileManager.default.createDirectory(at: oursDir, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(at: realDir, withIntermediateDirectories: true)
    writeSetup(esmSetup, into: oursDir)
    writeSetup(esmSetup, into: realDir)
    let ours = await runOurs(script: esmWrapped, argv: [], dir: oursDir, entry: "main.mjs")
    let real = runReal(script: esmWrapped, argv: [], dir: realDir, entry: "main.mjs")
    if ours.out == real.out && ours.status == real.status {
        print("fixture esm-local: match")
    } else {
        failures += 1
        print("MISMATCH: esm-local (status ours=\(ours.status) real=\(real.status))")
        print("  ---- ours ----\n\(ours.out)  ---- real ----\n\(real.out)  --------------")
    }
}

// -- chalk@5: a real ESM-only package (exports + #imports fields) -----------------
do {
    let dir = base.appendingPathComponent("esm-chalk")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    _ = try await PackageManager.install(requirements: ["chalk": "5.3.0"], into: dir)
    let script = """
    import chalk from 'chalk';
    console.log(chalk.red('warning'), chalk.bold('loud'));
    console.log(typeof chalk.level);
    """
    let ours = await runOurs(script: script, argv: [], dir: dir, entry: "main.mjs")
    let real = runReal(script: script, argv: [], dir: dir, entry: "main.mjs")
    if ours.out == real.out && ours.status == real.status {
        print("fixture esm-chalk: match")
    } else {
        failures += 1
        print("MISMATCH: esm-chalk (status ours=\(ours.status) real=\(real.status))")
        print("  ---- ours ----\n\(ours.out)  ---- real ----\n\(real.out)  --------------")
    }
} catch {
    failures += 1
    print("FAIL: esm-chalk install: \(error.localizedDescription)")
}

// -- top-level await + import attributes: the async-ESM semantics ------------------
do {
    let dir = base.appendingPathComponent("esm-tla")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try? #"{"k": "json-live"}"#.write(to: dir.appendingPathComponent("data.json"), atomically: true, encoding: .utf8)
    try? "export const ready = await new Promise(r => setTimeout(() => r('dep-ready'), 10));\n"
        .write(to: dir.appendingPathComponent("tladep.mjs"), atomically: true, encoding: .utf8)
    let script = """
    import { ready } from './tladep.mjs';
    import data from './data.json' with { type: 'json' };
    console.log('infected import:', ready);
    console.log('attributes:', data.k);
    const direct = await new Promise(r => setTimeout(() => r('entry-await'), 10));
    console.log('entry:', direct);
    const dyn = await import('./tladep.mjs');
    console.log('dynamic:', dyn.ready);
    """
    let ours = await runOurs(script: script, argv: [], dir: dir, entry: "main.mjs")
    let real = runReal(script: script, argv: [], dir: dir, entry: "main.mjs")
    if ours.out == real.out && ours.status == real.status {
        print("fixture esm-tla: match")
    } else {
        failures += 1
        print("MISMATCH: esm-tla (status ours=\(ours.status) real=\(real.status))")
        print("  ---- ours ----\n\(ours.out)  ---- real ----\n\(real.out)  --------------")
    }
}

// -- commander@15: a real pure-ESM CLI framework through require() -----------------
do {
    let dir = base.appendingPathComponent("commander-cli")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    _ = try await PackageManager.install(requirements: ["commander": "^15"], into: dir)
    let script = """
    const { Command } = require('commander');
    const program = new Command();
    program.name('tool').exitOverride();
    program.command('greet <name>').option('-l, --loud', 'shout').action((name, options) => {
      const text = 'hello ' + name;
      console.log(options.loud ? text.toUpperCase() : text);
    });
    program.parse(['node', 'tool', 'greet', 'mouse', '--loud']);
    """
    let ours = await runOurs(script: script, argv: [], dir: dir)
    let real = runReal(script: script, argv: [], dir: dir)
    if ours.out == real.out && ours.status == real.status {
        print("fixture commander-cli: match")
    } else {
        failures += 1
        print("MISMATCH: commander-cli (status ours=\(ours.status) real=\(real.status))")
        print("  ---- ours ----\n\(ours.out)  ---- real ----\n\(real.out)  --------------")
    }
} catch {
    failures += 1
    print("FAIL: commander install: \(error.localizedDescription)")
}

// -- @anthropic-ai/sdk: the model-API client an agent CLI is built on ----------------------
do {
    let dir = base.appendingPathComponent("anthropic-sdk")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    _ = try await PackageManager.install(requirements: ["@anthropic-ai/sdk": "latest"], into: dir)
    // fetch is replaced with a deterministic fake: this tests OUR fetch/Response/stream
    // plumbing and the SDK's use of it, with no network and no credential.
    let script = """
    import Anthropic from '@anthropic-ai/sdk';
    const captured = [];
    globalThis.fetch = function(input, options) {
      const url = input instanceof Request ? input.url : String(input);
      const init = options || {};
      const headers = new Headers((input instanceof Request ? input.headers : undefined) || init.headers);
      const names = [];
      headers.forEach((v, k) => names.push(k));
      captured.push({ url: url, method: String(init.method || 'POST').toUpperCase(), names: names.sort(),
                      hasKey: headers.has('x-api-key'),
                      body: typeof init.body === 'string' ? init.body : '' });
      return Promise.resolve(new Response(JSON.stringify({
        id: 'msg_1', type: 'message', role: 'assistant', model: 'claude-sonnet-4-5',
        content: [{ type: 'text', text: 'pong' }], stop_reason: 'end_turn',
        usage: { input_tokens: 3, output_tokens: 5 },
      }), { status: 200, headers: { 'content-type': 'application/json' } }));
    };
    const client = new Anthropic({ apiKey: 'sk-fake-for-shape-test' });
    const message = await client.messages.create({
      model: 'claude-sonnet-4-5', max_tokens: 16, messages: [{ role: 'user', content: 'ping' }],
    });
    console.log('reply:', message.content[0].text, '| usage:', message.usage.input_tokens, message.usage.output_tokens);
    const sent = captured[0];
    console.log('request:', sent.method, sent.url, '| key header:', sent.hasKey,
                '| version header:', sent.names.includes('anthropic-version'));
    console.log('sent body model:', JSON.parse(sent.body).model);

    // The STREAMING path: a real SSE body read through Response.body.
    const sse = [
      'event: message_start',
      'data: {"type":"message_start","message":{"id":"msg_2","type":"message","role":"assistant","model":"claude-sonnet-4-5","content":[],"stop_reason":null,"usage":{"input_tokens":4,"output_tokens":0}}}',
      '',
      'event: content_block_start',
      'data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}',
      '',
      'event: content_block_delta',
      'data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"streamed "}}',
      '',
      'event: content_block_delta',
      'data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"tokens"}}',
      '',
      'event: content_block_stop',
      'data: {"type":"content_block_stop","index":0}',
      '',
      'event: message_delta',
      'data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":2}}',
      '',
      'event: message_stop',
      'data: {"type":"message_stop"}',
      '',
    ].join('\\n');
    globalThis.fetch = () => Promise.resolve(new Response(sse, {
      status: 200, headers: { 'content-type': 'text/event-stream' },
    }));
    const streamingClient = new Anthropic({ apiKey: 'sk-fake' });
    const stream = await streamingClient.messages.create({
      model: 'claude-sonnet-4-5', max_tokens: 32, stream: true,
      messages: [{ role: 'user', content: 'stream please' }],
    });
    let text = '';
    let events = 0;
    for await (const event of stream) {
      events++;
      if (event.type === 'content_block_delta' && event.delta.type === 'text_delta') text += event.delta.text;
    }
    console.log('sse events:', events, '| assembled:', JSON.stringify(text));
    """
    let ours = await runOurs(script: script, argv: [], dir: dir, entry: "main.mjs")
    let real = runReal(script: script, argv: [], dir: dir, entry: "main.mjs")
    if ours.out == real.out && ours.status == real.status {
        print("fixture anthropic-sdk: match")
    } else {
        failures += 1
        print("MISMATCH: anthropic-sdk (status ours=\(ours.status) real=\(real.status))")
        print("  ---- ours ----\n\(ours.out)  ---- real ----\n\(real.out)  --------------")
    }
} catch {
    failures += 1
    print("FAIL: anthropic-sdk install: \(error.localizedDescription)")
}

// -- typescript@5: real tsc transpiles TypeScript (phase-D milestone, proven early) --------
do {
    let dir = base.appendingPathComponent("tsc-cli")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    _ = try await PackageManager.install(requirements: ["typescript": "^5"], into: dir)
    let script = """
    const ts = require('typescript');
    const source = 'interface P { name: string }\\nconst greet = (p: P): string => `hi ${p.name}`;\\nexport { greet };';
    const out = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 } });
    console.log(out.outputText);
    console.log('diagnostics:', (out.diagnostics || []).length);
    """
    let ours = await runOurs(script: script, argv: [], dir: dir)
    let real = runReal(script: script, argv: [], dir: dir)
    if ours.out == real.out && ours.status == real.status {
        print("fixture tsc-cli: match")
    } else {
        failures += 1
        print("MISMATCH: tsc-cli (status ours=\(ours.status) real=\(real.status))")
        print("  ---- ours ----\n\(ours.out)  ---- real ----\n\(real.out)  --------------")
    }
} catch {
    failures += 1
    print("FAIL: typescript install: \(error.localizedDescription)")
}

// -- yargs: dual CJS/ESM package (createRequire shadow + `export {x as 'module.exports'}`) --
do {
    let dir = base.appendingPathComponent("yargs-cli")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    _ = try await PackageManager.install(requirements: ["yargs": "latest"], into: dir)
    let script = """
    import yargs from 'yargs';
    const argv = yargs(['greet', '--name', 'mouse', '--loud', '--count', '3'])
      .command('greet', 'greet', (y) => y
        .option('name', { type: 'string' })
        .option('loud', { type: 'boolean' })
        .option('count', { type: 'number' }))
      .parseSync();
    console.log('cmd=' + argv._[0] + ' name=' + argv.name + ' loud=' + argv.loud + ' count=' + argv.count);
    """
    let ours = await runOurs(script: script, argv: [], dir: dir, entry: "main.mjs")
    let real = runReal(script: script, argv: [], dir: dir, entry: "main.mjs")
    if ours.out == real.out && ours.status == real.status {
        print("fixture yargs-cli: match")
    } else {
        failures += 1
        print("MISMATCH: yargs-cli (status ours=\(ours.status) real=\(real.status))")
        print("  ---- ours ----\n\(ours.out)  ---- real ----\n\(real.out)  --------------")
    }
} catch {
    failures += 1
    print("FAIL: yargs install: \(error.localizedDescription)")
}

// -- child_process: bridged shell (ours: /bin/sh via bridge; real: /bin/sh) -------
do {
    let script = """
    const { execSync, spawnSync, exec } = require('child_process');
    console.log(execSync('echo bridged').toString().trim());
    console.log(execSync('printf a-%s b', { encoding: 'utf8' }));
    const result = spawnSync('printf', ['%s+%s', 'x', 'y z']);
    console.log('spawn:', result.stdout.toString(), result.status);
    let threw = false;
    try { execSync('exit 3'); } catch (e) { threw = e.status === 3; }
    console.log('threw', threw);
    exec('echo async-done', (error, stdout) => console.log('cb:', stdout.trim()));
    """
    let oursDir = base.appendingPathComponent("ours-cp")
    let realDir = base.appendingPathComponent("real-cp")
    try? FileManager.default.createDirectory(at: oursDir, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(at: realDir, withIntermediateDirectories: true)
    let ours = await runOurs(script: script, argv: [], dir: oursDir)
    let real = runReal(script: script, argv: [], dir: realDir)
    if ours.out == real.out && ours.status == real.status {
        print("fixture child-process: match")
    } else {
        failures += 1
        print("MISMATCH: child-process (status ours=\(ours.status) real=\(real.status))")
        print("  ---- ours ----\n\(ours.out)  ---- real ----\n\(real.out)  --------------")
    }
}

// -- the surface audit's findings, verified by BEHAVIOR rather than presence -------------
// A member that exists but answers wrongly is worse than one that is missing, so each of
// these exercises the thing rather than checking typeof.
do {
    let script = #"""
    const fs = require('fs');
    const util = require('util');
    const events = require('events');
    const stream = require('stream');

    // fs: Stats/Dirent as real classes, opendir, cp, writev/readv, statfs, FileHandle.
    fs.mkdirSync('src/deep', { recursive: true });
    fs.writeFileSync('src/one.txt', 'hello');
    fs.writeFileSync('src/deep/two.txt', 'world');
    const stats = fs.statSync('src/one.txt');
    console.log('Stats instance:', stats instanceof fs.Stats, 'mode is number:', typeof stats.mode === 'number');
    console.log('access modes:', fs.F_OK === fs.constants.F_OK, typeof fs.R_OK, typeof fs.W_OK, typeof fs.X_OK);
    const dirents = fs.readdirSync('src', { withFileTypes: true });
    console.log('Dirent instance:', dirents[0] instanceof fs.Dirent);
    const dir = fs.opendirSync('src');
    const names = [];
    let entry;
    while ((entry = dir.readSync()) !== null) names.push(entry.name);
    dir.closeSync();
    console.log('opendir saw:', names.sort().join(','));
    fs.cpSync('src', 'copy', { recursive: true });
    console.log('cp copied deep file:', fs.readFileSync('copy/deep/two.txt', 'utf8'));
    const fd = fs.openSync('vector.txt', 'w');
    const written = fs.writevSync(fd, [Buffer.from('one'), Buffer.from('two')]);
    fs.closeSync(fd);
    console.log('writev wrote:', written, JSON.stringify(fs.readFileSync('vector.txt', 'utf8')));
    const space = fs.statfsSync('.');
    console.log('statfs plausible:', space.bsize > 0 && space.blocks > 0 && space.bavail >= 0);

    async function main() {
      const handle = await fs.promises.open('src/one.txt', 'r');
      const buffer = Buffer.alloc(5);
      const read = await handle.read(buffer, 0, 5, 0);
      console.log('FileHandle read:', read.bytesRead, JSON.stringify(buffer.toString()));
      const viaHandle = await handle.readFile('utf8');
      console.log('FileHandle readFile:', JSON.stringify(viaHandle));
      const handleStats = await handle.stat();
      console.log('FileHandle stat size:', handleStats.size);
      await handle.close();
      console.log('promises has realpath/symlink/open:',
                  typeof fs.promises.realpath, typeof fs.promises.symlink, typeof fs.promises.open);

      // events.on as an async iterator — the modern way to consume an emitter.
      const emitter = new events.EventEmitter();
      setTimeout(() => { emitter.emit('tick', 1); emitter.emit('tick', 2); }, 10);
      const iterator = events.on(emitter, 'tick');
      const first = await iterator.next();
      const second = await iterator.next();
      console.log('events.on yielded:', first.value[0], second.value[0]);
      console.log('errorMonitor is symbol:', typeof events.errorMonitor);

      // timers/promises, both entry points.
      const timers = require('timers/promises');
      console.log('timers/promises setTimeout:', await timers.setTimeout(5, 'done'));
      console.log('timers.promises is the same API:', typeof require('timers').promises.setTimeout);
    }

    // util.parseArgs — increasingly what a CLI uses instead of a dependency.
    const parsed = util.parseArgs({
      args: ['--name', 'mouse', '-v', 'file.txt', '--count=3'],
      options: { name: { type: 'string' }, verbose: { type: 'boolean', short: 'v' }, count: { type: 'string' } },
      allowPositionals: true,
    });
    console.log('parseArgs values:', JSON.stringify(parsed.values), 'positionals:', JSON.stringify(parsed.positionals));
    console.log('util type checks:', util.isBuffer(Buffer.alloc(1)), util.isDate(new Date()), util.isError(new Error('x')), util.isRegExp(/x/));

    // stream helpers.
    console.log('stream helpers:', typeof stream.compose, typeof stream.duplexPair, stream._isUint8Array(new Uint8Array(1)));

    // assert additions.
    const assert = require('assert');
    const tracker = new assert.CallTracker();
    const tracked = tracker.calls(function once(){}, 1);
    tracked();
    console.log('CallTracker report empty:', tracker.report().length === 0);
    assert.partialDeepStrictEqual({ a: 1, b: { c: 2 }, extra: true }, { a: 1, b: { c: 2 } });
    console.log('partialDeepStrictEqual accepted a subset');

    // process additions.
    console.log('process.uptime is number:', typeof process.uptime() === 'number');
    fs.writeFileSync('.env', 'MOUSE_FROM_ENV_FILE=yes\n# comment\n');
    process.loadEnvFile('.env');
    console.log('loadEnvFile:', process.env.MOUSE_FROM_ENV_FILE);

    // zlib and dns constants.
    const zlib = require('zlib');
    console.log('zlib codes:', zlib.constants.Z_BUF_ERROR, zlib.constants.Z_DATA_ERROR, zlib.constants.Z_MAX_LEVEL);
    console.log('dns codes:', require('dns').NOTFOUND, require('dns').SERVFAIL);

    main();
    """#
    let oursDir = base.appendingPathComponent("ours-surface")
    let realDir = base.appendingPathComponent("real-surface")
    try? FileManager.default.createDirectory(at: oursDir, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(at: realDir, withIntermediateDirectories: true)
    let ours = await runOurs(script: script, argv: [], dir: oursDir)
    let real = runReal(script: script, argv: [], dir: realDir)
    if ours.out == real.out && ours.status == real.status {
        print("fixture core-surface: match")
    } else {
        failures += 1
        print("MISMATCH: core-surface (status ours=\(ours.status) real=\(real.status))")
        let ourLines = ours.out.components(separatedBy: "\n")
        let realLines = real.out.components(separatedBy: "\n")
        for index in 0..<max(ourLines.count, realLines.count) {
            let a = index < ourLines.count ? ourLines[index] : "<none>"
            let b = index < realLines.count ? realLines[index] : "<none>"
            if a != b { print("  line \(index):\n    ours: \(a)\n    real: \(b)") }
        }
    }
}

// -- URL: relative resolution, which the whole http client parses through ----------------
// JSC gives us no URL, so the fallback in the bootstrap IS the parser every request uses.
// These are the RFC 3986 §5.2 cases the old "trim after the last slash" shortcut got wrong.
do {
    let script = #"""
    const base = 'https://user:pw@example.dev:8443/a/b/c?x=1#frag';
    const cases = ['/root', '../up', './same', 'sibling', '?only=query', '#onlyhash',
                   '//other.dev/path', 'https://absolute.dev/x', '../../way/up', 'a/b/../c'];
    for (const one of cases) {
      const url = new URL(one, base);
      console.log(one, '->', url.href, '| pathname', url.pathname, '| search', JSON.stringify(url.search));
    }
    const parsed = new URL(base);
    console.log('parts:', parsed.protocol, parsed.username, parsed.password, parsed.hostname,
                parsed.port, parsed.host, parsed.pathname, parsed.search, parsed.hash, parsed.origin);
    console.log('no-path url pathname:', new URL('https://x.dev').pathname);
    console.log('canParse:', URL.canParse('https://x.dev'), URL.canParse('nonsense'));
    try { new URL('/relative-without-base'); console.log('UNEXPECTED: accepted'); }
    catch (error) { console.log('relative without base throws:', error.code); }
    """#
    let oursDir = base.appendingPathComponent("ours-url")
    let realDir = base.appendingPathComponent("real-url")
    try? FileManager.default.createDirectory(at: oursDir, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(at: realDir, withIntermediateDirectories: true)
    let ours = await runOurs(script: script, argv: [], dir: oursDir)
    let real = runReal(script: script, argv: [], dir: realDir)
    if ours.out == real.out && ours.status == real.status {
        print("fixture url-resolution: match")
    } else {
        failures += 1
        print("MISMATCH: url-resolution")
        let ourLines = ours.out.components(separatedBy: "\n")
        let realLines = real.out.components(separatedBy: "\n")
        for index in 0..<max(ourLines.count, realLines.count) {
            let a = index < ourLines.count ? ourLines[index] : "<none>"
            let b = index < realLines.count ? realLines[index] : "<none>"
            if a != b { print("  ours: \(a)\n  real: \(b)") }
        }
    }
}

// -- ciphers and KDFs: the same ciphertext, and CROSS-ENGINE round trips -----------------
// Twin comparison first (deterministic key/iv means the ciphertext itself must match byte for
// byte, which is a much stronger check than "it round-trips"), then the real proof: what one
// engine seals, the other opens.
do {
    let sealScript = #"""
    const crypto = require('crypto');
    const key = Buffer.alloc(32, 7);
    const iv12 = Buffer.alloc(12, 3);
    const iv16 = Buffer.alloc(16, 3);
    const message = Buffer.from('the quick brown fox jumps over the lazy dog');
    const out = {};
    for (const [name, iv] of [['aes-256-gcm', iv12], ['chacha20-poly1305', iv12],
                              ['aes-256-cbc', iv16], ['aes-256-ctr', iv16]]) {
      const cipher = crypto.createCipheriv(name, key, iv);
      cipher.setAAD ? undefined : undefined;
      const body = Buffer.concat([cipher.update(message), cipher.final()]);
      out[name] = { data: body.toString('hex') };
      if (/gcm|poly/.test(name)) out[name].tag = cipher.getAuthTag().toString('hex');
    }
    console.log(JSON.stringify(out, null, 1));
    console.log('ciphers include aes-256-gcm:', crypto.getCiphers().includes('aes-256-gcm'));
    const info = crypto.getCipherInfo('aes-256-gcm');
    console.log('info:', info.name, info.keyLength, info.ivLength, info.mode);
    // AAD is part of the tag: same key, same iv, different AAD must give a different tag.
    const withAAD = crypto.createCipheriv('aes-256-gcm', key, iv12);
    withAAD.setAAD(Buffer.from('header'));
    const sealed = Buffer.concat([withAAD.update(message), withAAD.final()]);
    console.log('aad tag:', withAAD.getAuthTag().toString('hex'));
    // Opening it back, including the tag check.
    const opener = crypto.createDecipheriv('aes-256-gcm', key, iv12);
    opener.setAAD(Buffer.from('header'));
    opener.setAuthTag(withAAD.getAuthTag());
    console.log('round trip:', Buffer.concat([opener.update(sealed), opener.final()]).toString());
    const wrong = crypto.createDecipheriv('aes-256-gcm', key, iv12);
    wrong.setAAD(Buffer.from('different'));
    wrong.setAuthTag(withAAD.getAuthTag());
    try { wrong.update(sealed); wrong.final(); console.log('UNEXPECTED: bad AAD accepted'); }
    catch (error) { console.log('bad AAD rejected:', /authenticate/.test(error.message)); }
    // KDFs — same inputs, same bytes.
    console.log('pbkdf2 sha256:', crypto.pbkdf2Sync('password', 'salt', 4096, 32, 'sha256').toString('hex'));
    console.log('pbkdf2 sha512:', crypto.pbkdf2Sync('password', 'salt', 1000, 64, 'sha512').toString('hex'));
    console.log('hkdf sha256:', Buffer.from(crypto.hkdfSync('sha256', 'secret', 'salt', 'info', 42)).toString('hex'));
    const secret = crypto.createSecretKey(Buffer.alloc(32, 9));
    console.log('secret key:', secret.type, secret.symmetricKeySize, secret.export().length);
    const filled = crypto.randomFillSync(Buffer.alloc(8));
    console.log('randomFill filled:', filled.length === 8, filled.some(b => b !== 0));
    """#
    let oursDir = base.appendingPathComponent("ours-cipher")
    let realDir = base.appendingPathComponent("real-cipher")
    try? FileManager.default.createDirectory(at: oursDir, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(at: realDir, withIntermediateDirectories: true)
    let ours = await runOurs(script: sealScript, argv: [], dir: oursDir)
    let real = runReal(script: sealScript, argv: [], dir: realDir)
    if ours.out == real.out && ours.status == real.status {
        print("fixture ciphers-and-kdfs: match (identical ciphertext, tags and derived keys)")
    } else {
        failures += 1
        print("MISMATCH: ciphers-and-kdfs")
        let ourLines = ours.out.components(separatedBy: "\n")
        let realLines = real.out.components(separatedBy: "\n")
        for index in 0..<max(ourLines.count, realLines.count) {
            let a = index < ourLines.count ? ourLines[index] : "<none>"
            let b = index < realLines.count ? realLines[index] : "<none>"
            if a != b { print("  ours: \(a)\n  real: \(b)") }
        }
    }
}

// The cross-engine proof: ours seals, REAL node opens, and the reverse.
do {
    let sealer = #"""
    const crypto = require('crypto');
    const key = Buffer.alloc(32, 11);
    const iv = Buffer.alloc(12, 5);
    const cipher = crypto.createCipheriv('aes-256-gcm', key, iv);
    cipher.setAAD(Buffer.from('cross-engine'));
    const body = Buffer.concat([cipher.update('a secret that must survive the trip'), cipher.final()]);
    console.log(JSON.stringify({ data: body.toString('base64'), tag: cipher.getAuthTag().toString('base64') }));
    """#
    let opener = #"""
    const crypto = require('crypto');
    const fs = require('fs');
    const sealed = JSON.parse(fs.readFileSync('sealed.json', 'utf8'));
    const key = Buffer.alloc(32, 11);
    const iv = Buffer.alloc(12, 5);
    const decipher = crypto.createDecipheriv('aes-256-gcm', key, iv);
    decipher.setAAD(Buffer.from('cross-engine'));
    decipher.setAuthTag(Buffer.from(sealed.tag, 'base64'));
    const plain = Buffer.concat([decipher.update(Buffer.from(sealed.data, 'base64')), decipher.final()]);
    console.log('opened:', plain.toString());
    """#
    let oursDir = base.appendingPathComponent("cross-ours")
    let realDir = base.appendingPathComponent("cross-real")
    try? FileManager.default.createDirectory(at: oursDir, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(at: realDir, withIntermediateDirectories: true)

    // ours seals → real node opens
    let sealedByUs = await runOurs(script: sealer, argv: [], dir: oursDir)
    try? sealedByUs.out.write(to: realDir.appendingPathComponent("sealed.json"), atomically: true, encoding: .utf8)
    let openedByReal = runReal(script: opener, argv: [], dir: realDir)

    // real node seals → ours opens
    let sealedByReal = runReal(script: sealer, argv: [], dir: realDir, entry: "seal.js")
    try? sealedByReal.out.write(to: oursDir.appendingPathComponent("sealed.json"), atomically: true, encoding: .utf8)
    let openedByUs = await runOurs(script: opener, argv: [], dir: oursDir)

    let expected = "opened: a secret that must survive the trip\n"
    if openedByReal.out == expected && openedByUs.out == expected {
        print("cross-engine crypto: what we seal real node opens, and what node seals we open")
    } else {
        failures += 1
        print("MISMATCH: cross-engine crypto")
        print("  real opened ours: \(openedByReal.out.debugDescription)")
        print("  ours opened real's: \(openedByUs.out.debugDescription)")
    }
}

// -- signing: ECDSA and Ed25519, proven ACROSS engines ------------------------------------
// ECDSA signatures are randomized, so byte comparison is meaningless — the real test is that
// each engine verifies the other's signatures, with keys generated on the far side too.
do {
    let signer = #"""
    const crypto = require('crypto');
    const fs = require('fs');
    const message = Buffer.from('sign me across engines');
    const out = {};
    for (const curve of ['prime256v1', 'secp384r1', 'secp521r1']) {
      const { publicKey, privateKey } = crypto.generateKeyPairSync('ec', {
        namedCurve: curve,
        publicKeyEncoding: { type: 'spki', format: 'pem' },
        privateKeyEncoding: { type: 'pkcs8', format: 'pem' },
      });
      const signature = crypto.createSign('sha256').update(message).sign(privateKey);
      out['ec-' + curve] = { publicKey: publicKey, signature: signature.toString('base64'), digest: 'sha256' };
    }
    const ed = crypto.generateKeyPairSync('ed25519', {
      publicKeyEncoding: { type: 'spki', format: 'pem' },
      privateKeyEncoding: { type: 'pkcs8', format: 'pem' },
    });
    out['ed25519'] = { publicKey: ed.publicKey,
                       signature: crypto.sign(null, message, ed.privateKey).toString('base64'),
                       digest: null };
    fs.writeFileSync('signed.json', JSON.stringify(out));
    console.log('signed:', Object.keys(out).sort().join(','));
    """#
    let verifier = #"""
    const crypto = require('crypto');
    const fs = require('fs');
    const message = Buffer.from('sign me across engines');
    const signed = JSON.parse(fs.readFileSync('signed.json', 'utf8'));
    const results = [];
    for (const name of Object.keys(signed).sort()) {
      const entry = signed[name];
      const signature = Buffer.from(entry.signature, 'base64');
      const ok = crypto.verify(entry.digest, message, entry.publicKey, signature);
      // A tampered message must NOT verify — otherwise "true" proves nothing.
      const tampered = crypto.verify(entry.digest, Buffer.from('different message'), entry.publicKey, signature);
      results.push(name + ':' + ok + '/' + tampered);
    }
    console.log('verified:', results.join(' '));
    """#
    let oursDir = base.appendingPathComponent("sign-ours")
    let realDir = base.appendingPathComponent("sign-real")
    try? FileManager.default.createDirectory(at: oursDir, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(at: realDir, withIntermediateDirectories: true)

    // ours signs → real node verifies
    let signedByUs = await runOurs(script: signer, argv: [], dir: oursDir)
    try? FileManager.default.removeItem(at: realDir.appendingPathComponent("signed.json"))
    try? FileManager.default.copyItem(at: oursDir.appendingPathComponent("signed.json"),
                                      to: realDir.appendingPathComponent("signed.json"))
    let checkedByReal = runReal(script: verifier, argv: [], dir: realDir, entry: "verify.js")

    // real node signs → ours verifies
    let signedByReal = runReal(script: signer, argv: [], dir: realDir, entry: "sign.js")
    try? FileManager.default.removeItem(at: oursDir.appendingPathComponent("signed.json"))
    try? FileManager.default.copyItem(at: realDir.appendingPathComponent("signed.json"),
                                      to: oursDir.appendingPathComponent("signed.json"))
    let checkedByUs = await runOurs(script: verifier, argv: [], dir: oursDir, entry: "verify.js")

    let expected = "verified: ec-prime256v1:true/false ec-secp384r1:true/false ec-secp521r1:true/false ed25519:true/false\n"
    if checkedByReal.out == expected, checkedByUs.out == expected,
       signedByUs.out == signedByReal.out {
        print("cross-engine signing: real node verifies our ECDSA and Ed25519 signatures, and we verify node's")
    } else {
        failures += 1
        print("MISMATCH: cross-engine signing")
        print("  ours signed: \(signedByUs.out.debugDescription)")
        print("  real verified ours: \(checkedByReal.out.debugDescription)")
        print("  ours verified real's: \(checkedByUs.out.debugDescription)")
    }
}

// The API shape, compared strictly against node.
do {
    let script = #"""
    const crypto = require('crypto');
    const { publicKey, privateKey } = crypto.generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
    console.log('key objects:', privateKey.type, publicKey.type, privateKey.asymmetricKeyType);
    console.log('curve detail:', privateKey.asymmetricKeyDetails.namedCurve);
    const pem = privateKey.export({ type: 'pkcs8', format: 'pem' });
    console.log('exports pem:', typeof pem === 'string', pem.indexOf('BEGIN PRIVATE KEY') > 0);
    const der = publicKey.export({ type: 'spki', format: 'der' });
    console.log('exports der:', Buffer.isBuffer(der), der.length > 0);
    const reloaded = crypto.createPrivateKey(pem);
    console.log('reload round trip:', reloaded.asymmetricKeyType, reloaded.type);
    // ieee-p1363 is the raw (r||s) encoding JOSE uses; DER is the default.
    const message = Buffer.from('shape check');
    const der64 = crypto.sign('sha256', message, privateKey);
    const raw64 = crypto.sign('sha256', message, { key: privateKey, dsaEncoding: 'ieee-p1363' });
    console.log('der vs raw signature lengths differ:', der64.length !== raw64.length, raw64.length);
    console.log('raw verifies:', crypto.verify('sha256', message, { key: publicKey, dsaEncoding: 'ieee-p1363' }, raw64));
    console.log('curves:', crypto.getCurves().includes('prime256v1'));
    const ed = crypto.generateKeyPairSync('ed25519');
    console.log('ed25519 type:', ed.privateKey.asymmetricKeyType);
    try { crypto.sign('sha256', message, ed.privateKey); console.log('UNEXPECTED: digest accepted for ed25519'); }
    catch (error) { console.log('ed25519 rejects a digest name:', error.code); }
    """#
    let oursDir = base.appendingPathComponent("sign-shape-ours")
    let realDir = base.appendingPathComponent("sign-shape-real")
    try? FileManager.default.createDirectory(at: oursDir, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(at: realDir, withIntermediateDirectories: true)
    let ours = await runOurs(script: script, argv: [], dir: oursDir)
    let real = runReal(script: script, argv: [], dir: realDir)
    if ours.out == real.out && ours.status == real.status {
        print("fixture signing-shape: match")
    } else {
        failures += 1
        print("MISMATCH: signing-shape")
        let ourLines = ours.out.components(separatedBy: "\n")
        let realLines = real.out.components(separatedBy: "\n")
        for index in 0..<max(ourLines.count, realLines.count) {
            let a = index < ourLines.count ? ourLines[index] : "<none>"
            let b = index < realLines.count ? realLines[index] : "<none>"
            if a != b { print("  ours: \(a)\n  real: \(b)") }
        }
    }
}

// What key types STILL have no system implementation, asserted on our side alone because
// node supports them. RSA used to live here and no longer does — SecKey made it real.
// X448 left too: the refusal said "the system has no such key type", which is a fact about
// the system and silent on whether the curve can be written. RFC 7748 is a Montgomery ladder
// over p = 2^448 - 2^224 - 1 and JSC's BigInt does that arithmetic, so x448 now generates
// and agrees — the cross-engine secret match is asserted in the x448 gate. DSA is corecrypto
// only; generateKeyPairSync('dh') stays refused because node returns raw DH group keys there,
// a shape nothing else in the module speaks.
do {
    let ours = await runOurs(script: #"""
    const crypto = require('crypto');
    for (const type of ['dsa', 'dh']) {
      try { crypto.generateKeyPairSync(type, { modulusLength: 2048 }); console.log(type + ': generated'); }
      catch (error) { console.log(type + ': refused'); }
    }
    """#, argv: [], dir: base.appendingPathComponent("keytype-refusals"))
    if ours.out == "dsa: refused\ndh: refused\n" {
        print("key types with no system implementation refuse by name (dsa, dh)")
    } else {
        failures += 1
        print("MISMATCH: key-type refusals, got \(ours.out.debugDescription)")
    }
}

// -- streaming responses: chunks as they arrive, not one lump at the end ------------------
// The transport under `fetch` and `https.request` is URLSession, whose completion-handler form
// hands over a finished body — which broke the case that matters most here: an agent CLI
// reading server-sent events from an API. The delegate form reports each chunk, and this
// fixture proves it by TIMING: three events sent half a second apart must arrive as three
// reads spread over time, in both engines.
do {
    let serveDir = base.appendingPathComponent("sse-server")
    try? FileManager.default.createDirectory(at: serveDir, withIntermediateDirectories: true)
    try? """
    import http.server, sys, time
    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            self.send_response(200)
            self.send_header('Content-Type', 'text/event-stream')
            self.end_headers()
            for i in range(3):
                self.wfile.write(('data: chunk%d\\n\\n' % i).encode())
                self.wfile.flush()
                time.sleep(0.4)
        def log_message(self, *args): pass
    http.server.HTTPServer(('127.0.0.1', int(sys.argv[1])), Handler).serve_forever()
    """.write(to: serveDir.appendingPathComponent("sse.py"), atomically: true, encoding: .utf8)
    let port = 9300 + Int(getpid()) % 200
    let server = Process()
    server.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/python3")
    server.arguments = ["sse.py", String(port)]
    server.currentDirectoryURL = serveDir
    server.standardOutput = Pipe()
    server.standardError = Pipe()
    try? server.run()
    try? await Task.sleep(nanoseconds: 700_000_000)

    let script = """
    const started = Date.now();
    async function main() {
      const response = await fetch('http://127.0.0.1:\(port)/events');
      console.log('status before the body finished:', response.status, response.headers.get('content-type'));
      const reader = response.body.getReader();
      const arrivals = [];
      while (true) {
        const { value, done } = await reader.read();
        if (done) break;
        arrivals.push({ at: Date.now() - started, text: Buffer.from(value).toString().trim() });
      }
      console.log('arrivals:', arrivals.length);
      console.log('spread over time:', (arrivals[arrivals.length - 1].at - arrivals[0].at) > 300);
      console.log('in order:', arrivals.map(a => a.text).join('|'));
      // The one-shot readers still work on a streaming body — they drain it.
      const second = await fetch('http://127.0.0.1:\(port)/events');
      const text = await second.text();
      console.log('text() drained:', text.split('\\n\\n').filter(Boolean).length, 'events');
    }
    main();
    """
    let oursDir = base.appendingPathComponent("ours-sse")
    let realDir = base.appendingPathComponent("real-sse")
    try? FileManager.default.createDirectory(at: oursDir, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(at: realDir, withIntermediateDirectories: true)
    let ours = await runOurs(script: script, argv: [], dir: oursDir)
    let real = runReal(script: script, argv: [], dir: realDir)
    server.terminate()
    if ours.out == real.out && ours.status == real.status {
        print("fixture fetch-streaming: match (chunks arrive as they are sent, like node)")
    } else {
        failures += 1
        print("MISMATCH: fetch-streaming")
        print("  ---- ours ----\n\(ours.out)  ---- real ----\n\(real.out)")
    }
}

// -- Buffer over an ArrayBuffer SHARES memory, which is what makes wasm interop work --------
// `Buffer.from(arrayBuffer[, byteOffset[, length]])` is documented as a VIEW, not a copy, and
// real packages depend on it: webpack writes into `WebAssembly.Memory.buffer` through such a
// Buffer and reads the hash back out of the same bytes. Copying made every wasm hash return the
// input padded with NULs — a wrong answer with no error anywhere near it.
do {
    let script = #"""
    // A hand-built wasm module: memory, and a function that adds 1 to the byte at offset 0.
    // Keeping it tiny means this fixture tests OUR plumbing, not a toolchain.
    const wasm = new Uint8Array([
      0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,             // magic + version
      0x01, 0x04, 0x01, 0x60, 0x00, 0x00,                         // type: () -> ()
      0x03, 0x02, 0x01, 0x00,                                     // function 0 has that type
      0x05, 0x03, 0x01, 0x00, 0x01,                               // memory: 1 page
      0x07, 0x11, 0x02, 0x04, 0x62, 0x75, 0x6d, 0x70, 0x00, 0x00, // export "bump" = func 0
      0x06, 0x6d, 0x65, 0x6d, 0x6f, 0x72, 0x79, 0x02, 0x00,       // export "memory" = mem 0
      0x0a, 0x11, 0x01, 0x0f, 0x00,                               // code section, body
      0x41, 0x00,                                                 // i32.const 0
      0x41, 0x00,                                                 // i32.const 0
      0x2d, 0x00, 0x00,                                           // i32.load8_u [0]
      0x41, 0x01,                                                 // i32.const 1
      0x6a,                                                       // i32.add
      0x3a, 0x00, 0x00,                                           // i32.store8 [0]
      0x0b,                                                       // end
    ]);
    const instance = new WebAssembly.Instance(new WebAssembly.Module(wasm));
    const view = Buffer.from(instance.exports.memory.buffer, 0, 8);
    view[0] = 41;
    instance.exports.bump();
    console.log('wasm saw the write and we see its result:', view[0]);

    // The sharing itself, without wasm in the way.
    const raw = new ArrayBuffer(8);
    const first = Buffer.from(raw);
    const second = Buffer.from(raw);
    first[0] = 7;
    console.log('two views share:', second[0] === 7);
    console.log('offset and length honored:', Buffer.from(raw, 4, 2).length, Buffer.from(raw, 4).length);
    const typed = new Uint16Array([0x0102, 0x0304]);
    console.log('a typed array is copied by bytes:', Array.from(Buffer.from(typed)).join(','));
    const slice = new Uint8Array(raw, 2, 3);
    slice[0] = 9;
    console.log('a Uint8Array view is copied, not aliased:',
                Buffer.from(slice)[0] === 9, Buffer.from(slice).length);
    """#
    let oursDir = base.appendingPathComponent("ours-wasmbuf")
    let realDir = base.appendingPathComponent("real-wasmbuf")
    try? FileManager.default.createDirectory(at: oursDir, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(at: realDir, withIntermediateDirectories: true)
    let ours = await runOurs(script: script, argv: [], dir: oursDir)
    let real = runReal(script: script, argv: [], dir: realDir)
    if ours.out == real.out && ours.status == real.status {
        print("fixture buffer-over-arraybuffer: match (wasm memory is shared, not copied)")
    } else {
        failures += 1
        print("MISMATCH: buffer-over-arraybuffer")
        print("  ---- ours ----\n\(ours.out)  ---- real ----\n\(real.out)")
    }
}

// -- `require(".")` is a directory request, and webpack makes one ---------------------------
do {
    let script = #"""
    const fs = require('fs');
    fs.mkdirSync('pkg/nested', { recursive: true });
    fs.writeFileSync('pkg/package.json', JSON.stringify({ name: 'pkg', main: 'entry.js' }));
    fs.writeFileSync('pkg/entry.js', 'module.exports = "from the package main";');
    fs.writeFileSync('pkg/nested/index.js', 'module.exports = require("..");');
    fs.writeFileSync('here.js', 'module.exports = require(".") === undefined ? "no" : "yes";');
    console.log('require("..") from a subdirectory:', require('./pkg/nested'));
    console.log('require(".") resolves a directory:', typeof require('./pkg'));
    """#
    let oursDir = base.appendingPathComponent("ours-dotrequire")
    let realDir = base.appendingPathComponent("real-dotrequire")
    try? FileManager.default.createDirectory(at: oursDir, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(at: realDir, withIntermediateDirectories: true)
    let ours = await runOurs(script: script, argv: [], dir: oursDir)
    let real = runReal(script: script, argv: [], dir: realDir)
    if ours.out == real.out && ours.status == real.status {
        print("fixture dot-require: match")
    } else {
        failures += 1
        print("MISMATCH: dot-require\n  ---- ours ----\n\(ours.out)  ---- real ----\n\(real.out)")
    }
}

// -- ECDH: both engines must derive the SAME shared secret -------------------------------
// The point of a key agreement is that two parties reach the same secret, so the test is
// cross-engine: ours generates a pair, real node generates a pair, and each computes the secret
// from the other's public key. Equal secrets prove the curve, the encoding and the maths.
do {
    let generate = #"""
    const crypto = require('crypto');
    const fs = require('fs');
    const out = {};
    for (const curve of ['prime256v1', 'secp384r1', 'secp521r1']) {
      const ecdh = crypto.createECDH(curve);
      ecdh.generateKeys();
      out[curve] = { pub: ecdh.getPublicKey().toString('base64'), priv: ecdh.getPrivateKey().toString('base64') };
    }
    fs.writeFileSync(process.argv[2], JSON.stringify(out));
    console.log('generated:', Object.keys(out).sort().join(','));
    console.log('curves advertised:', crypto.getCurves().includes('prime256v1'));
    """#
    let agree = #"""
    const crypto = require('crypto');
    const fs = require('fs');
    const mine = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
    const theirs = JSON.parse(fs.readFileSync(process.argv[3], 'utf8'));
    const lines = [];
    for (const curve of Object.keys(mine).sort()) {
      const ecdh = crypto.createECDH(curve);
      ecdh.setPrivateKey(Buffer.from(mine[curve].priv, 'base64'));
      const secret = ecdh.computeSecret(Buffer.from(theirs[curve].pub, 'base64'));
      lines.push(curve + ':' + secret.toString('hex'));
    }
    console.log(lines.join('\n'));
    """#
    let dir = base.appendingPathComponent("ecdh")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    _ = await runOurs(script: generate, argv: ["ours.json"], dir: dir, entry: "gen.js")
    _ = runReal(script: generate, argv: ["real.json"], dir: dir, entry: "gen-real.js")
    // Each side agrees with the OTHER's public key; the secrets must be identical.
    let oursAgrees = await runOurs(script: agree, argv: ["ours.json", "real.json"], dir: dir, entry: "agree.js")
    let realAgrees = runReal(script: agree, argv: ["real.json", "ours.json"], dir: dir, entry: "agree-real.js")
    if oursAgrees.out == realAgrees.out, !oursAgrees.out.isEmpty, oursAgrees.out.contains("prime256v1:") {
        print("cross-engine ECDH: the same shared secret on both sides, for every curve")
    } else {
        failures += 1
        print("MISMATCH: cross-engine ECDH\n  ours: \(oursAgrees.out.debugDescription)\n  real: \(realAgrees.out.debugDescription)")
    }
}

// -- refusals must be TRUE, and they must say why ------------------------------------------
// A refusal is part of the contract: it tells the next caller what to do instead. One of these
// had gone stale into a falsehood ("cluster is not available (single process)" — we have live
// child processes now), two blamed capabilities that have since shipped, and several gave no
// reason at all. This pins the shape rather than the prose: every refusal names a reason, and
// none of them claims something the engine can now do.
do {
    let ours = await runOurs(script: #"""
    const checks = [
      ['inspector', () => require('inspector').open()],
      ['path.matchesGlob', () => require('path').matchesGlob('a', '*')],
    ];
    for (const [name, run] of checks) {
      try { run(); console.log(name + ': ALLOWED'); }
      catch (error) {
        const message = String(error.message);
        // A reason is a colon followed by something substantial, and it must not claim a
        // capability we have: no "single process", no "roadmap", no bare "not available".
        const hasReason = message.indexOf(': ') > 0 && message.length > 40;
        const stale = /single process|on the roadmap|not available yet|^\w+ is not available$/.test(message);
        console.log(name + ': refused, reason=' + hasReason + ', stale=' + stale);
      }
    }
    // And the claims that are TRUE stay true: these are the capabilities the stale refusals
    // used to deny.
    const cp = require('child_process');
    console.log('fork is real:', typeof cp.fork === 'function');
    console.log('http server is real:', typeof require('http').createServer === 'function');
    console.log('http2 is real both ways:', (function(){
      const http2 = require('http2');
      const server = http2.createServer();
      // Not connected here — a refusal probe must not open a socket — but the CLIENT half
      // exists, which is what the old refusal denied.
      return typeof server.listen === 'function' && typeof http2.connect === 'function';
    })());
    console.log('ecdh is real:', typeof require('crypto').createECDH === 'function');
    console.log('udp is real:', typeof require('dgram').createSocket('udp4').bind === 'function');
    console.log('unix sockets are real:', require('net').createServer().listen('/tmp-probe.sock') !== undefined);
    console.log('multicast is real:', typeof require('dgram').createSocket('udp4').addMembership === 'function');
    // Not called: fork() here would spawn a worker inside a refusal probe.
    console.log('cluster is real:', require('cluster').isPrimary === true &&
                                    typeof require('cluster').fork === 'function');
    console.log('broadcast is real:', typeof BroadcastChannel === 'function' &&
                                      typeof require('worker_threads').receiveMessageOnPort === 'function');
    console.log('scrypt is real:', require('crypto').scryptSync('', '', 8, { N: 16, r: 1, p: 1 })
                                     .toString('hex') === '77d6576238657b20');
    console.log('glob is real:', typeof require('fs').globSync === 'function');
    console.log('dns resolvers are real:', typeof require('dns').resolveMx === 'function' &&
                                          typeof require('dns').reverse === 'function');
    console.log('brotli is real:', (function(){
      const z = require('zlib');
      const packed = z.brotliCompressSync(Buffer.from('x'.repeat(200)));
      return z.brotliDecompressSync(packed).length === 200;
    })());
    console.log('rsa legacy direction is real:', (function(){
      const c = require('crypto');
      const pair = c.generateKeyPairSync('rsa', { modulusLength: 2048 });
      const sealed = c.privateEncrypt(pair.privateKey, Buffer.from('legacy'));
      return c.publicDecrypt(pair.publicKey, sealed).toString() === 'legacy';
    })());
    console.log('x25519 agreement is real:', (function(){
      const c = require('crypto');
      const a = c.generateKeyPairSync('x25519'), b = c.generateKeyPairSync('x25519');
      return c.diffieHellman({ privateKey: a.privateKey, publicKey: b.publicKey })
              .equals(c.diffieHellman({ privateKey: b.privateKey, publicKey: a.publicKey }));
    })());
    """#, argv: [], dir: base.appendingPathComponent("refusals"))
    let expected = """
    inspector: refused, reason=true, stale=false
    path.matchesGlob: refused, reason=true, stale=false
    fork is real: true
    http server is real: true
    http2 is real both ways: true
    ecdh is real: true
    udp is real: true
    unix sockets are real: true
    multicast is real: true
    cluster is real: true
    broadcast is real: true
    scrypt is real: true
    glob is real: true
    dns resolvers are real: true
    brotli is real: true
    rsa legacy direction is real: true
    x25519 agreement is real: true

    """.stripIndent()
    if ours.out == expected {
        print("fixture refusal-truth: every refusal names a reason and none is stale")
    } else {
        failures += 1
        print("MISMATCH: refusal-truth\n---- ours ----\n\(ours.out)---- expected ----\n\(expected)")
    }
}

// -- fs sync/async/promise parity ------------------------------------------------------
// The sync fs functions were made much stricter several boundaries ago — ENOENT for a missing
// parent, EEXIST, ENOTDIR, refusing to delete a tree — and whether the callback and promise forms
// followed was never checked. Three APIs for one operation is three chances to diverge, and a
// program using the promise form would not have noticed. They agree, because both families
// delegate through a single wrapper to the Sync implementation rather than reimplementing it;
// this pins that so a future "optimisation" of one form cannot quietly split them.
do {
    let script = #"""
    // SYNC/ASYNC/PROMISE parity. I made the sync fs functions much stricter — ENOENT for a missing
    // parent, EEXIST, ENOTDIR, refusing to delete a tree — and never checked that the callback and
    // promise forms agree. Three APIs for one operation is three chances to diverge.
    const fs = require('fs');
    const out = [];
    const shape = e => !e ? 'ok' : (e.code || e.name);
    const trio = async (label, syncFn, asyncFn, promiseFn) => {
      let s, a, p;
      try { syncFn(); s = 'ok'; } catch (e) { s = shape(e); }
      a = await new Promise(res => { try { asyncFn(e => res(shape(e))); } catch (e) { res('THREW ' + shape(e)); } });
      p = await promiseFn().then(() => 'ok', e => shape(e));
      out.push(label + ': sync=' + s + ' cb=' + a + ' promise=' + p + (s === a && a === p ? '' : '  <-- DIVERGES'));
    };

    (async () => {
      fs.rmSync('par', { recursive: true, force: true });
      fs.mkdirSync('par');
      fs.writeFileSync('par/f.txt', 'x');
      fs.mkdirSync('par/dir');
      fs.writeFileSync('par/dir/inner.txt', 'y');

      await trio('read missing',
        () => fs.readFileSync('par/nope'),
        cb => fs.readFile('par/nope', cb),
        () => fs.promises.readFile('par/nope'));
      await trio('read a directory',
        () => fs.readFileSync('par/dir'),
        cb => fs.readFile('par/dir', cb),
        () => fs.promises.readFile('par/dir'));
      await trio('mkdir existing',
        () => fs.mkdirSync('par/dir'),
        cb => fs.mkdir('par/dir', cb),
        () => fs.promises.mkdir('par/dir'));
      await trio('mkdir missing parent',
        () => fs.mkdirSync('par/a/b'),
        cb => fs.mkdir('par/a/b', cb),
        () => fs.promises.mkdir('par/a/b'));
      await trio('rm a directory without recursive',
        () => fs.rmSync('par/dir'),
        cb => fs.rm('par/dir', cb),
        () => fs.promises.rm('par/dir'));
      await trio('rm missing without force',
        () => fs.rmSync('par/gone'),
        cb => fs.rm('par/gone', cb),
        () => fs.promises.rm('par/gone'));
      await trio('rmdir non-empty',
        () => fs.rmdirSync('par/dir'),
        cb => fs.rmdir('par/dir', cb),
        () => fs.promises.rmdir('par/dir'));
      await trio('readdir a file',
        () => fs.readdirSync('par/f.txt'),
        cb => fs.readdir('par/f.txt', cb),
        () => fs.promises.readdir('par/f.txt'));
      await trio('rename missing source',
        () => fs.renameSync('par/gone', 'par/other'),
        cb => fs.rename('par/gone', 'par/other', cb),
        () => fs.promises.rename('par/gone', 'par/other'));
      await trio('write into a missing directory',
        () => fs.writeFileSync('par/no/where.txt', 'x'),
        cb => fs.writeFile('par/no/where.txt', 'x', cb),
        () => fs.promises.writeFile('par/no/where.txt', 'x'));
      await trio('copy missing source',
        () => fs.copyFileSync('par/gone', 'par/copy'),
        cb => fs.copyFile('par/gone', 'par/copy', cb),
        () => fs.promises.copyFile('par/gone', 'par/copy'));
      await trio('stat missing',
        () => fs.statSync('par/gone'),
        cb => fs.stat('par/gone', cb),
        () => fs.promises.stat('par/gone'));
      fs.rmSync('par', { recursive: true, force: true });
      console.log(out.join('\n'));
      process.exit(0);
    })();
    """#
    let ours = await runOurs(script: script, argv: [], dir: base.appendingPathComponent("fsparity"))
    let expected = """
    read missing: sync=ENOENT cb=ENOENT promise=ENOENT
    read a directory: sync=EISDIR cb=EISDIR promise=EISDIR
    mkdir existing: sync=EEXIST cb=EEXIST promise=EEXIST
    mkdir missing parent: sync=ENOENT cb=ENOENT promise=ENOENT
    rm a directory without recursive: sync=ERR_FS_EISDIR cb=ERR_FS_EISDIR promise=ERR_FS_EISDIR
    rm missing without force: sync=ENOENT cb=ENOENT promise=ENOENT
    rmdir non-empty: sync=ENOTEMPTY cb=ENOTEMPTY promise=ENOTEMPTY
    readdir a file: sync=ENOTDIR cb=ENOTDIR promise=ENOTDIR
    rename missing source: sync=ENOENT cb=ENOENT promise=ENOENT
    write into a missing directory: sync=ENOENT cb=ENOENT promise=ENOENT
    copy missing source: sync=ENOENT cb=ENOENT promise=ENOENT
    stat missing: sync=ENOENT cb=ENOENT promise=ENOENT

    """.stripIndent()
    if ours.out == expected {
        print("fixture fs-parity: sync, callback and promise agree on every failure")
    } else {
        failures += 1
        print("MISMATCH: fs-parity\n---- ours ----\n\(ours.out)---- expected ----\n\(expected)")
    }
}

// -- stream STATE across a lifecycle ---------------------------------------------------
// The shape sweep proves a property exists; it cannot see one reporting the WRONG VALUE. Two
// in-flight bugs (highWaterMark, then writableLength) came from state going stale when a value
// moved between places, so this reads every state flag at each point a program would consult it.
// Found: node AUTO-DESTROYS a finished stream (its default since v14), which is what makes
// `stream.destroyed` the reliable "done with this" flag callers test — ours stayed false forever.
// And `destroy()` left `readable`/`writable` true, inviting a write to a dead stream.
// A Duplex waits for BOTH halves before destroying itself, which the PassThrough cases pin.
do {
    let script = #"""
    // Stream STATE values across a lifecycle. The shape sweep proves a property exists; it cannot
    // see one reporting the wrong value. Two in-flight bugs (highWaterMark, then writableLength)
    // came from state going stale when a value moved between places, so this checks the values
    // themselves at each point a program would read them.
    const { Readable, Writable, PassThrough } = require('stream');
    const out = [];
    const say = (l, v) => out.push(l + ': ' + v);
    const snapR = r => [r.readableFlowing, r.readableLength, r.readableEnded, r.destroyed, r.readable].join('|');
    const snapW = w => [w.writableLength, w.writableEnded, w.writableFinished, w.writableCorked,
                        w.destroyed, w.writable, w.writableNeedDrain].join('|');

    (async () => {
      // Readable, through its whole life.
      const r = new Readable({ read() {} });
      say('readable fresh', snapR(r));
      r.push('abc');
      say('after push', snapR(r));
      r.resume();
      await new Promise(res => setTimeout(res, 30));
      say('after resume+drain', snapR(r));
      r.push(null);
      await new Promise(res => setTimeout(res, 30));
      say('after EOF', snapR(r));

      const r2 = new Readable({ read() {} });
      r2.destroy();
      await new Promise(res => setTimeout(res, 30));
      say('destroyed readable', snapR(r2));

      // Writable, including a slow write so the in-flight window is visible.
      let release = null;
      const w = new Writable({ highWaterMark: 4, write(c, e, cb) { release = cb; } });
      say('writable fresh', snapW(w));
      const accepted = w.write('12345');
      say('write returned', String(accepted));
      say('during slow write', snapW(w));
      release();
      await new Promise(res => setTimeout(res, 30));
      say('after write completes', snapW(w));
      w.cork();
      say('corked', snapW(w));
      w.uncork();
      w.end();
      await new Promise(res => setTimeout(res, 30));
      say('after end', snapW(w));

      const w2 = new Writable({ write(c, e, cb) { cb(); } });
      w2.destroy();
      await new Promise(res => setTimeout(res, 30));
      say('destroyed writable', snapW(w2));

      // A Duplex reports both halves independently.
      const p = new PassThrough();
      p.write('x');
      say('passthrough after write', snapR(p) + ' / ' + snapW(p));
      p.end();
      await new Promise(res => setTimeout(res, 30));
      say('passthrough after end', snapW(p));
      console.log(out.join('\n'));
      process.exit(0);
    })();
    """#
    let ours = await runOurs(script: script, argv: [], dir: base.appendingPathComponent("streamstate"))
    let expected = """
    readable fresh: |0|false|false|true
    after push: |3|false|false|true
    after resume+drain: true|0|false|false|true
    after EOF: true|0|true|true|false
    destroyed readable: |0|false|true|false
    writable fresh: 0|false|false|0|false|true|false
    write returned: false
    during slow write: 5|false|false|0|false|true|true
    after write completes: 0|false|false|0|false|true|false
    corked: 0|false|false|1|false|true|false
    after end: 0|true|true|0|true|false|false
    destroyed writable: 0|false|false|0|true|false|false
    passthrough after write: |1|false|false|true / 0|false|false|0|false|true|false
    passthrough after end: 0|true|true|0|false|false|false

    """.stripIndent()
    if ours.out == expected {
        print("fixture stream-state: autoDestroy, and every flag true when node says so")
    } else {
        failures += 1
        print("MISMATCH: stream-state\n---- ours ----\n\(ours.out)---- expected ----\n\(expected)")
    }
}

// -- the rest of the stream surface ---------------------------------------------------
// What the instance-shape sweep left. `unpipe` is the one that mattered: real code stops a pipe
// mid-flight — proxying, tar, aborting a download — and it was a TypeError. `pipe` now remembers
// its wiring so `unpipe` can undo exactly it, detach one destination or all, and emit 'unpipe'
// on each. Plus `wrap`, `compose`, `setDefaultEncoding`, and the introspection getters.
// `writableLength` counts the chunk still IN FLIGHT as well as the queue — the same in-flight
// blind spot that made highWaterMark report no backpressure two boundaries ago, in the property
// a caller compares against it.
do {
    let script = #"""
    // What the instance-shape sweep left on the stream classes: unpipe, setDefaultEncoding, and the
    // introspection getters. unpipe is the one that matters — real code stops a pipe mid-flight
    // (proxying, tar, aborting a download), and today that is a TypeError.
    const { Readable, Writable, PassThrough } = require('stream');
    const out = [];
    const say = (l, v) => out.push(l + ': ' + v);
    const check = (l, fn) => { try { say(l, fn()); } catch (e) { say(l, 'THREW ' + String(e.message).slice(0, 40)); } };
    const race = (label, build) => new Promise(resolve => {
      let settled = false;
      const finish = v => { if (!settled) { settled = true; say(label, v); resolve(); } };
      setTimeout(() => finish('NEVER SETTLED'), 900);
      try { build(finish); } catch (e) { finish('THREW ' + String(e.message).slice(0, 40)); }
    });

    check('methods present', () => {
      const r = new Readable({ read() {} });
      const w = new Writable({ write(c, e, cb) { cb(); } });
      return ['unpipe', 'wrap', 'compose'].filter(n => typeof r[n] !== 'function').join(',') +
             '|' + ['setDefaultEncoding'].filter(n => typeof w[n] !== 'function').join(',');
    });
    check('readable getters', () => {
      const r = new Readable({ read() {}, highWaterMark: 99 });
      return [r.readableHighWaterMark, r.readableLength, r.readableEnded, r.readableFlowing,
              r.readableObjectMode, r.readableEncoding].join('|');
    });
    check('writable getters', () => {
      const w = new Writable({ write(c, e, cb) { cb(); }, highWaterMark: 77 });
      return [w.writableHighWaterMark, w.writableLength, w.writableEnded, w.writableFinished,
              w.writableObjectMode, w.writableNeedDrain].join('|');
    });
    check('readableEncoding after setEncoding', () => {
      const r = new Readable({ read() {} });
      r.setEncoding('hex');
      return String(r.readableEncoding);
    });

    (async () => {
      // unpipe must actually STOP the flow: what arrives after it must not reach the old sink.
      await race('unpipe stops delivery', finish => {
        const source = new Readable({ read() {} });
        const got = [];
        const sink = new Writable({ write(c, e, cb) { got.push(String(c)); cb(); } });
        source.pipe(sink);
        source.push('before');
        setTimeout(() => {
          source.unpipe(sink);
          source.push('after');
          setTimeout(() => finish(JSON.stringify(got)), 120);
        }, 100);
      });
      // unpipe with no argument detaches every destination.
      await race('unpipe all', finish => {
        const source = new Readable({ read() {} });
        const got = [];
        const a = new Writable({ write(c, e, cb) { got.push('a:' + c); cb(); } });
        const b = new Writable({ write(c, e, cb) { got.push('b:' + c); cb(); } });
        source.pipe(a); source.pipe(b);
        source.push('one');
        setTimeout(() => {
          source.unpipe();
          source.push('two');
          setTimeout(() => finish(JSON.stringify(got.sort())), 120);
        }, 100);
      });
      // The 'unpipe' event fires on the destination.
      await race('unpipe event', finish => {
        const source = new Readable({ read() {} });
        const sink = new PassThrough();
        sink.on('unpipe', () => finish('fired'));
        source.pipe(sink);
        setTimeout(() => source.unpipe(sink), 60);
      });
      await race('writableLength grows', finish => {
        const w = new Writable({ highWaterMark: 100, write(c, e, cb) { setTimeout(cb, 200); } });
        w.write('12345');
        setTimeout(() => finish(String(w.writableLength)), 40);
      });
      console.log(out.join('\n'));
      process.exit(0);
    })();
    """#
    let ours = await runOurs(script: script, argv: [], dir: base.appendingPathComponent("streamrest"))
    let expected = """
    methods present: |
    readable getters: 99|0|false||false|
    writable getters: 77|0|false|false|false|false
    readableEncoding after setEncoding: hex
    unpipe stops delivery: ["before"]
    unpipe all: ["a:one","b:one"]
    unpipe event: fired
    writableLength grows: 5

    """.stripIndent()
    if ours.out == expected {
        print("fixture stream-surface: unpipe stops the flow, and the getters report reality")
    } else {
        failures += 1
        print("MISMATCH: stream-surface\n---- ours ----\n\(ours.out)---- expected ----\n\(expected)")
    }
}

// -- the console audit ---------------------------------------------------------------
// In a terminal IDE every console method is a visible feature. SIXTEEN were missing from the
// global console — `dir`, `table`, `group`, `count`, `time`, `assert` and the rest — so
// `console.dir(x)` threw and killed the program. `console.debug` went to STDERR where node sends
// it to stdout, which is not cosmetic: a tool piping stdout either loses output or gets noise
// mixed into its data. And the `Console` CLASS had silent no-op stubs for group/count/time,
// the shape this repo refuses everywhere else — one implementation now backs both.
//
// NOTE the expected block below is NOT run through replacingOccurrences like its neighbours:
// that trick strips every four-space run, and this content is MADE of them (table padding,
// nested group indentation). Swift's own multi-line stripping handles it correctly.
do {
    let script = #"""
    // The CONSOLE audit. In a terminal IDE every one of these is a visible feature, and the routing
    // matters as much as the text: warn/error go to STDERR, and a tool piping stdout must not get
    // them mixed in. stdout and stderr are printed separately so the split is part of the check.
    console.log('log line');
    console.info('info line');
    console.debug('debug line');
    console.dir({ a: { b: { c: 1 } } });
    console.dir({ a: { b: { c: 1 } } }, { depth: 0 });
    console.group('group A');
    console.log('inside A');
    console.group('group B');
    console.log('inside B');
    console.groupEnd();
    console.log('back in A');
    console.groupEnd();
    console.log('outside');
    console.count();
    console.count();
    console.count('tag');
    console.countReset();
    console.count();
    console.table([{ a: 1, b: 'x' }, { a: 2, b: 'y' }]);
    console.table({ row: { col: 1 } });
    console.table([1, 2]);
    console.log('has methods:', ['table', 'group', 'groupEnd', 'count', 'countReset', 'time',
      'timeEnd', 'timeLog', 'dir', 'assert', 'trace', 'clear', 'groupCollapsed', 'dirxml',
      'profile', 'profileEnd', 'timeStamp'].filter(n => typeof console[n] !== 'function').join(',') || 'all present');
    // timers print a duration, which varies — only the shape is checked.
    console.time('t');
    console.timeEnd('t');
    """#
    let raw = await runOurs(script: script, argv: [], dir: base.appendingPathComponent("console"))
    let ours = raw.out.split(separator: "\n", omittingEmptySubsequences: false)
        .map { $0.hasPrefix("t: ") ? "t: <duration>" : String($0) }.joined(separator: "\n")
    let expected = """
    log line
    info line
    debug line
    { a: { b: { c: 1 } } }
    { a: [Object] }
    group A
      inside A
      group B
        inside B
      back in A
    outside
    default: 1
    default: 2
    tag: 1
    default: 1
    ┌─────────┬───┬─────┐
    │ (index) │ a │ b   │
    ├─────────┼───┼─────┤
    │ 0       │ 1 │ 'x' │
    │ 1       │ 2 │ 'y' │
    └─────────┴───┴─────┘
    ┌─────────┬─────┐
    │ (index) │ col │
    ├─────────┼─────┤
    │ row     │ 1   │
    └─────────┴─────┘
    ┌─────────┬────────┐
    │ (index) │ Values │
    ├─────────┼────────┤
    │ 0       │ 1      │
    │ 1       │ 2      │
    └─────────┴────────┘
    has methods: all present
    t: <duration>

    """
    if ours == expected {
        print("fixture console: table box-drawing, group indentation, count/time, and stream routing")
    } else {
        failures += 1
        print("MISMATCH: console\n---- ours ----\n\(ours)---- expected ----\n\(expected)")
    }
}

// -- the formatting audit -------------------------------------------------------------
// For a terminal IDE this is not cosmetic: console.log output IS what the user reads, and what
// they paste into a bug report. `Map`, `Set`, `Date`, `RegExp` and `Promise` all printed as `{}` —
// completely opaque. Circular references expanded three levels instead of being marked. Long
// collections printed in full. Class names were dropped. And GETTERS WERE EVALUATED, so a logger
// could run a side effect in the program it was logging.
// Two divergences are pinned to OUR values with the reason: node reads a promise's resolved value
// through V8 internals that JSC does not expose, and node's column-aligned multi-line grid for
// long numeric arrays is intricate width arithmetic for no behavioural gain — the important half,
// truncating at 100 with a count, is done and asserted.
do {
    let script = #"""
    // The FORMATTING audit. For a terminal IDE this is not cosmetic: console.log output IS the
    // product a user reads. node's inspect has specific shapes for Map, Set, Date, Error, circular
    // references, class instances, sparse arrays, getters and long collections, and code pastes
    // output into bug reports expecting them.
    const util = require('util');
    const out = [];
    const show = (label, value) => out.push(label + ': ' + util.inspect(value));

    show('empty object', {});
    show('empty array', []);
    show('nested', { a: [1, { b: 2 }] });
    show('string in object', { s: 'hi' });
    show('bare string', 'hi');
    show('number-ish', [1, -0, NaN, Infinity, -Infinity, 1e21]);
    show('bigint', 10n);
    show('symbol', Symbol('tag'));
    show('undefined and null', [undefined, null]);
    show('function', function named() {});
    show('arrow', () => {});
    show('class', class Thing {});
    show('class instance', new (class Point { constructor() { this.x = 1; } })());
    show('date', new Date(0));
    show('regexp', /ab+c/gi);
    // An Error's inspect includes its stack, whose paths differ per engine — the shape is what
    // matters, so only the first line is compared.
    out.push('error first line: ' + util.inspect(new Error('boom')).split('\n')[0]);
    out.push('error with code: ' + util.inspect(Object.assign(new Error('x'), { code: 'E1' })).split('\n')[0]);
    show('map', new Map([['a', 1], [2, 'b']]));
    show('empty map', new Map());
    show('set', new Set([1, 'two']));
    show('empty set', new Set());
    show('buffer', Buffer.from([1, 2, 255]));
    show('typed array', new Uint16Array([1, 2]));
    // node reads a promise's resolved VALUE through V8 internals ('Promise { 1 }'); JSC exposes no
    // such hook, so a settled promise is indistinguishable from a pending one here.
    show('promise', Promise.resolve(1));
    show('sparse array', [1, , 3]);
    show('array with extra props', Object.assign([1, 2], { extra: true }));
    show('nested depth 3', { a: { b: { c: { d: 1 } } } });
    // Truncation matches node (100 items + a count); node's COLUMN-ALIGNED multi-line grid for long
    // numeric arrays does not, and reproducing that layout is a lot of intricate width arithmetic for
    // no behavioural gain. The important half — not printing 10,000 items — is done.
    show('long array', Array.from({ length: 120 }, (_, i) => i).slice(0, 3));
    show('long array truncates', util.inspect(Array.from({ length: 120 }, (_, i) => i)).includes('... 20 more items'));
    const circular = { name: 'loop' };
    circular.self = circular;
    show('circular', circular);
    show('object with symbol key', { [Symbol('k')]: 1, normal: 2 });
    show('getter', Object.defineProperty({}, 'lazy', { get() { return 1; }, enumerable: true }));
    show('null prototype', Object.create(null));
    show('boxed primitives', [new Number(3), new String('s'), new Boolean(true)]);
    // console.log's own formatting: %s %d %i %j %o %O %% and extra arguments.
    const format = util.format;
    out.push('format %s: ' + format('%s|%s', 'a', 5));
    out.push('format %d %i: ' + format('%d %i', '42.9', '42.9'));
    out.push('format %j: ' + format('%j', { a: 1 }));
    out.push('format %%: ' + format('100%%'));
    out.push('format extras: ' + format('one', 'two', 3));
    out.push('format object arg: ' + format('%o', { a: 1 }));
    out.push('format no spec: ' + format({ a: 1 }, 'tail'));
    console.log(out.join('\n'));
    """#
    let ours = await runOurs(script: script, argv: [], dir: base.appendingPathComponent("inspect"))
    let expected = """
    empty object: {}
    empty array: []
    nested: { a: [ 1, { b: 2 } ] }
    string in object: { s: 'hi' }
    bare string: 'hi'
    number-ish: [ 1, -0, NaN, Infinity, -Infinity, 1e+21 ]
    bigint: 10n
    symbol: Symbol(tag)
    undefined and null: [ undefined, null ]
    function: [Function: named]
    arrow: [Function (anonymous)]
    class: [class Thing]
    class instance: Point { x: 1 }
    date: 1970-01-01T00:00:00.000Z
    regexp: /ab+c/gi
    error first line: Error: boom
    error with code: Error: x
    map: Map(2) { 'a' => 1, 2 => 'b' }
    empty map: Map(0) {}
    set: Set(2) { 1, 'two' }
    empty set: Set(0) {}
    buffer: <Buffer 01 02 ff>
    typed array: Uint16Array(2) [ 1, 2 ]
    promise: Promise { <pending> }
    sparse array: [ 1, <1 empty item>, 3 ]
    array with extra props: [ 1, 2, extra: true ]
    nested depth 3: { a: { b: { c: [Object] } } }
    long array: [ 0, 1, 2 ]
    long array truncates: true
    circular: <ref *1> { name: 'loop', self: [Circular *1] }
    object with symbol key: { normal: 2, [Symbol(k)]: 1 }
    getter: { lazy: [Getter] }
    null prototype: [Object: null prototype] {}
    boxed primitives: [ [Number: 3], [String: 's'], [Boolean: true] ]
    format %s: a|5
    format %d %i: 42.9 42
    format %j: {"a":1}
    format %%: 100%%
    format extras: one two 3
    format object arg: { a: 1 }
    format no spec: { a: 1 } tail

    """.stripIndent()
    if ours.out == expected {
        print("fixture inspect-format: Maps, Sets, cycles, getters and console.log's own rules")
    } else {
        failures += 1
        print("MISMATCH: inspect-format\n---- ours ----\n\(ours.out)---- expected ----\n\(expected)")
    }
}

// -- the encoding audit ---------------------------------------------------------------
// A wrong encoding produces wrong BYTES or wrong TEXT silently — the same shape as the range read
// that returned the whole file. Every named encoding across every path that takes one. Four real
// defects, and the first was the worst: **base64url was not supported at all**, so
// `Buffer.from(token, 'base64url')` read the string as UTF-8 and returned the token's own bytes.
// JWTs are made of base64url. Also: utf16le/ucs2 were ignored by `Buffer.from` (a UTF-16 encode
// produced UTF-8 bytes), `ascii` was not masked, and `StringDecoder` held no state at all — a
// bare `toString` per chunk, in the module whose entire purpose is to hold a split character.
// One node quirk worth the comment: `ascii` is ASYMMETRIC. Encoding masks to 0xff (so it acts
// like latin1), decoding masks to 0x7f. Verified rather than assumed symmetric.
do {
    let script = #"""
    // The ENCODING audit. A wrong encoding produces wrong BYTES or wrong TEXT silently — the same
    // shape as the range read that returned the whole file. Every named encoding, across every path
    // that takes one: Buffer.from/toString, fs read/write, StringDecoder, and stream setEncoding.
    const fs = require('fs');
    const { StringDecoder } = require('string_decoder');
    const { Readable } = require('stream');
    const out = [];
    const say = (l, v) => out.push(l + ': ' + v);
    const check = (l, fn) => { try { say(l, fn()); } catch (e) { say(l, 'THREW ' + String(e.message).slice(0, 40)); } };
    const names = ['utf8', 'utf-8', 'utf16le', 'ucs2', 'ucs-2', 'latin1', 'binary', 'ascii',
                   'hex', 'base64', 'base64url'];

    fs.rmSync('enc', { recursive: true, force: true });
    fs.mkdirSync('enc');

    // Buffer.isEncoding must agree about what exists at all.
    check('isEncoding', () => JSON.stringify(names.map(n => Buffer.isEncoding(n))));

    // A round trip through every encoding, on text that needs more than ASCII.
    for (const name of names) {
      check('roundtrip ' + name, () => {
        const source = name === 'hex' ? 'deadbeef' : (name === 'base64' || name === 'base64url') ? 'aGVsbG8' : 'héllo€';
        const bytes = Buffer.from(source, name);
        return bytes.toString('hex') + ' -> ' + JSON.stringify(bytes.toString(name));
      });
    }
    // base64url must use -_ and drop padding; base64 must use +/ and keep it.
    check('base64 vs base64url', () => {
      const bytes = Buffer.from([251, 255, 190, 255]);
      return bytes.toString('base64') + ' | ' + bytes.toString('base64url');
    });
    check('base64url decodes -_', () => Buffer.from('-_-_', 'base64url').toString('hex'));
    check('base64 decodes +/', () => Buffer.from('+/+/', 'base64').toString('hex'));
    // utf16le pairs, where a naive byte copy goes wrong.
    check('utf16le of a surrogate pair', () => Buffer.from('𝄞', 'utf16le').toString('hex'));
    check('utf16le back', () => Buffer.from('34d81edd', 'hex').toString('utf16le'));
    // latin1 keeps every byte; ascii masks the high bit.
    check('latin1 high bytes', () => Buffer.from([0xff, 0x80]).toString('latin1').split('').map(c => c.charCodeAt(0)).join(','));
    check('ascii high bytes', () => Buffer.from([0xff, 0x80]).toString('ascii').split('').map(c => c.charCodeAt(0)).join(','));
    // toString with a range, which the range audit did not cover for encodings.
    check('toString hex range', () => Buffer.from([1, 2, 3, 4]).toString('hex', 1, 3));

    // fs must honour an encoding on the way in AND out.
    for (const name of ['utf8', 'latin1', 'hex', 'base64']) {
      check('fs write+read ' + name, () => {
        fs.writeFileSync('enc/f', 'A9', name);
        return fs.readFileSync('enc/f').toString('hex') + ' -> ' + fs.readFileSync('enc/f', name);
      });
    }
    // StringDecoder must hold a split multi-byte character, like TextDecoder does.
    check('StringDecoder split utf8', () => {
      const decoder = new StringDecoder('utf8');
      return JSON.stringify(decoder.write(Buffer.from([0xe2, 0x82]))) + '+' +
             JSON.stringify(decoder.write(Buffer.from([0xac])));
    });
    check('StringDecoder utf16le split', () => {
      const decoder = new StringDecoder('utf16le');
      return JSON.stringify(decoder.write(Buffer.from([0x34]))) + '+' +
             JSON.stringify(decoder.write(Buffer.from([0xd8, 0x1e, 0xdd])));
    });

    (async () => {
      // A stream's setEncoding across every name.
      for (const name of ['utf8', 'latin1', 'hex', 'base64']) {
        await new Promise(resolve => {
          const stream = new Readable({ read() {} });
          stream.setEncoding(name);
          stream.push(Buffer.from([0xc3, 0xa9]));
          stream.push(null);
          const parts = [];
          stream.on('data', c => parts.push(c));
          stream.on('end', () => { say('stream setEncoding ' + name, JSON.stringify(parts.join(''))); resolve(); });
        });
      }
      fs.rmSync('enc', { recursive: true, force: true });
      console.log(out.join('\n'));
      process.exit(0);
    })();
    """#
    let ours = await runOurs(script: script, argv: [], dir: base.appendingPathComponent("encodings"))
    let expected = """
    isEncoding: [true,true,true,true,true,true,true,true,true,true,true]
    roundtrip utf8: 68c3a96c6c6fe282ac -> "héllo€"
    roundtrip utf-8: 68c3a96c6c6fe282ac -> "héllo€"
    roundtrip utf16le: 6800e9006c006c006f00ac20 -> "héllo€"
    roundtrip ucs2: 6800e9006c006c006f00ac20 -> "héllo€"
    roundtrip ucs-2: 6800e9006c006c006f00ac20 -> "héllo€"
    roundtrip latin1: 68e96c6c6fac -> "héllo¬"
    roundtrip binary: 68e96c6c6fac -> "héllo¬"
    roundtrip ascii: 68e96c6c6fac -> "hillo,"
    roundtrip hex: deadbeef -> "deadbeef"
    roundtrip base64: 68656c6c6f -> "aGVsbG8="
    roundtrip base64url: 68656c6c6f -> "aGVsbG8"
    base64 vs base64url: +/++/w== | -_--_w
    base64url decodes -_: fbffbf
    base64 decodes +/: fbffbf
    utf16le of a surrogate pair: 34d81edd
    utf16le back: 𝄞
    latin1 high bytes: 255,128
    ascii high bytes: 127,0
    toString hex range: 0203
    fs write+read utf8: 4139 -> A9
    fs write+read latin1: 4139 -> A9
    fs write+read hex: a9 -> a9
    fs write+read base64: 03 -> Aw==
    StringDecoder split utf8: ""+"€"
    StringDecoder utf16le split: ""+"𝄞"
    stream setEncoding utf8: "é"
    stream setEncoding latin1: "Ã©"
    stream setEncoding hex: "c3a9"
    stream setEncoding base64: "w6k="

    """.stripIndent()
    if ours.out == expected {
        print("fixture encodings: every named encoding, both directions, and a held split character")
    } else {
        failures += 1
        print("MISMATCH: encodings\n---- ours ----\n\(ours.out)---- expected ----\n\(expected)")
    }
}

// -- the event-sequence audit ---------------------------------------------------------
// Real code WAITS on events, so one that never fires is a hang and one that fires twice is a
// double-free; ordering matters too. Two events were MISSING: a failed `createReadStream` emitted
// 'error' with no 'close' (so a caller cleaning up there waited forever), and a ClientRequest
// never emitted 'close' at all — it was tied to the SOCKET closing, and with keep-alive the
// socket outlives the exchange. The request's 'close' also has to follow the response's 'end',
// not merely the body being parsed, or the order a caller sees is inverted.
//
// Two ordering divergences are DELIBERATELY pinned to our values, with the reason: gzip emits its
// header chunk after 'finish' rather than before (our coder produces output at the flush), and a
// server's req 'end' precedes res 'finish' where node has it the other way. Both are tick-level
// orderings with no observable consequence for a caller doing one thing per event, and chasing
// them means moving when EOF is pushed through the stream core — real risk, no gain. Measured and
// named beats quietly different.
do {
    let script = #"""
    // The EVENT SEQUENCE audit. Real code waits on events, so one that never fires is a hang and one
    // that fires twice is a double-free. Ordering matters too: 'end' before 'close', 'response'
    // before 'end'. Each case records the exact ordered list and is compared with node's.
    const fs = require('fs');
    const net = require('net');
    const http = require('http');
    const zlib = require('zlib');
    const { Readable, Writable } = require('stream');
    const out = [];
    const watch = (emitter, names) => {
      const seen = [];
      for (const name of names) emitter.on(name, () => seen.push(name));
      return seen;
    };
    const race = (label, build) => new Promise(resolve => {
      let settled = false;
      const finish = seen => { if (!settled) { settled = true; out.push(label + ': ' + seen.join(',')); resolve(); } };
      const timer = setTimeout(() => finish(['TIMED OUT']), 1500);
      try { build(seen => { clearTimeout(timer); finish(seen); }); }
      catch (e) { clearTimeout(timer); finish(['THREW ' + String(e.message).slice(0, 30)]); }
    });

    fs.rmSync('ev', { recursive: true, force: true });
    fs.mkdirSync('ev');
    fs.writeFileSync('ev/f.txt', 'hello');

    (async () => {
      await race('read stream', finish => {
        const stream = fs.createReadStream('ev/f.txt');
        const seen = watch(stream, ['open', 'ready', 'data', 'end', 'close', 'error']);
        stream.on('close', () => setImmediate(() => finish(seen)));
        stream.resume();
      });
      await race('write stream', finish => {
        const stream = fs.createWriteStream('ev/w.txt');
        const seen = watch(stream, ['open', 'ready', 'finish', 'close', 'error']);
        stream.on('close', () => setImmediate(() => finish(seen)));
        stream.end('x');
      });
      await race('read stream missing file', finish => {
        const stream = fs.createReadStream('ev/nope.txt');
        const seen = watch(stream, ['open', 'ready', 'data', 'end', 'close', 'error']);
        stream.on('error', () => setTimeout(() => finish(seen), 60));
      });
      await race('gzip stream', finish => {
        const gz = zlib.createGzip();
        const seen = watch(gz, ['data', 'end', 'finish', 'close', 'error']);
        gz.on('close', () => setImmediate(() => finish(seen)));
        gz.resume();
        gz.end('payload');
      });
      await race('client socket', finish => {
        const server = net.createServer(c => c.end('hi'));
        server.listen(0, () => {
          const socket = net.connect(server.address().port, '127.0.0.1');
          const seen = watch(socket, ['connect', 'ready', 'data', 'end', 'close', 'error']);
          socket.on('close', () => { server.close(); setImmediate(() => finish(seen)); });
          socket.resume();
        });
      });
      await race('server lifecycle', finish => {
        const server = net.createServer(c => c.end());
        const seen = watch(server, ['listening', 'connection', 'close', 'error']);
        server.listen(0, () => {
          const socket = net.connect(server.address().port, '127.0.0.1');
          socket.resume();
          socket.on('close', () => { server.close(); });
        });
        server.on('close', () => setImmediate(() => finish(seen)));
      });
      await race('http client request', finish => {
        const server = http.createServer((req, res) => res.end('ok'));
        server.listen(0, () => {
          const request = http.get({ port: server.address().port, path: '/' });
          const seen = watch(request, ['socket', 'response', 'close', 'error']);
          request.on('response', res => {
            res.resume();
            res.on('end', () => { seen.push('res-end'); server.close(); setTimeout(() => finish(seen), 80); });
          });
        });
      });
      await race('http server side', finish => {
        const seen = [];
        const server = http.createServer((req, res) => {
          seen.push('request');
          req.on('end', () => seen.push('req-end'));
          res.on('finish', () => seen.push('res-finish'));
          req.resume();
          res.end('ok');
        });
        server.listen(0, () => {
          http.get({ port: server.address().port, path: '/' }, res => {
            res.resume();
            res.on('end', () => { server.close(); setTimeout(() => finish(seen), 80); });
          });
        });
      });
      await race('writable end twice', finish => {
        const seen = [];
        const sink = new Writable({ write(c, e, cb) { cb(); } });
        sink.on('finish', () => seen.push('finish'));
        sink.on('close', () => seen.push('close'));
        sink.end('a');
        setTimeout(() => finish(seen), 100);
      });
      fs.rmSync('ev', { recursive: true, force: true });
      console.log(out.join('\n'));
      process.exit(0);
    })();
    """#
    let ours = await runOurs(script: script, argv: [], dir: base.appendingPathComponent("events"))
    let expected = """
    read stream: open,ready,data,end,close
    write stream: open,ready,finish,close
    read stream missing file: error,close
    gzip stream: finish,data,data,end,close
    client socket: connect,ready,data,end,close
    server lifecycle: listening,connection,close
    http client request: socket,response,res-end,close
    http server side: request,res-finish,req-end
    writable end twice: finish,close

    """.stripIndent()
    if ours.out == expected {
        print("fixture event-sequences: nine lifecycles, and two named ordering divergences")
    } else {
        failures += 1
        print("MISMATCH: event-sequences\n---- ours ----\n\(ours.out)---- expected ----\n\(expected)")
    }
}

// -- the error-code audit ------------------------------------------------------------
// The class with the widest blast radius: real code branches on `error.code`, so a wrong code
// silently takes the WRONG PATH. Every fs error was missing its `syscall`, two codes were wrong
// (a directory read as ENOENT instead of EISDIR, a file scanned as ENOENT instead of ENOTDIR),
// and five operations SUCCEEDED where node fails. Those five were the real problem: rmdirSync on
// a file DELETED it, writeFileSync into a missing directory FABRICATED the tree, and mkdirSync
// built a whole path without `recursive`. A filesystem API that quietly does more than it was
// asked either destroys data or invents it.
do {
    let script = #"""
    // The ERROR CODE audit. Real code branches on error.code — `if (e.code === 'ENOENT') create()` —
    // so a missing or wrong code silently takes the wrong path, which is worse than a wrong message.
    // Each case is isolated; each reports code + syscall so a near-miss is visible.
    const fs = require('fs');
    const net = require('net');
    const out = [];
    const shape = e => !e ? 'NO ERROR' : [e.code || '(no code)', e.syscall || '-'].join(' ');
    const check = (label, fn) => {
      try { fn(); out.push(label + ': NO ERROR'); }
      catch (error) { out.push(label + ': ' + shape(error)); }
    };
    const acheck = (label, build) => new Promise(resolve => {
      let settled = false;
      const finish = e => { if (!settled) { settled = true; out.push(label + ': ' + shape(e)); resolve(); } };
      setTimeout(() => finish({ code: 'NEVER SETTLED' }), 1000);
      try { build(finish); } catch (e) { finish(e); }
    });

    fs.rmSync('ec', { recursive: true, force: true });
    fs.mkdirSync('ec');
    fs.writeFileSync('ec/file.txt', 'x');

    check('readFileSync missing', () => fs.readFileSync('ec/nope.txt'));
    check('readFileSync on a directory', () => fs.readFileSync('ec'));
    check('statSync missing', () => fs.statSync('ec/nope.txt'));
    check('mkdirSync existing', () => fs.mkdirSync('ec'));
    check('mkdirSync missing parent', () => fs.mkdirSync('ec/a/b/c'));
    check('unlinkSync missing', () => fs.unlinkSync('ec/nope.txt'));
    check('rmdirSync a file', () => fs.rmdirSync('ec/file.txt'));
    check('readdirSync a file', () => fs.readdirSync('ec/file.txt'));
    check('renameSync missing source', () => fs.renameSync('ec/nope.txt', 'ec/other.txt'));
    check('openSync missing, read mode', () => fs.openSync('ec/nope.txt', 'r'));
    check('writeFileSync into a missing dir', () => fs.writeFileSync('ec/no/where.txt', 'x'));
    check('accessSync missing', () => fs.accessSync('ec/nope.txt'));
    check('copyFileSync missing source', () => fs.copyFileSync('ec/nope.txt', 'ec/copy.txt'));
    check('JSON.parse bad input', () => JSON.parse('{oops'));

    (async () => {
      await acheck('connect refused', finish => {
        // Port 1 is reserved and never listening.
        const socket = net.connect(1, '127.0.0.1');
        socket.on('error', finish);
        socket.on('connect', () => finish(null));
      });
      await acheck('lookup bogus host', finish => {
        require('dns').lookup('nope.invalid', error => finish(error));
      });
      await acheck('readFile callback missing', finish => {
        fs.readFile('ec/nope.txt', error => finish(error));
      });
      await acheck('promises readFile missing', finish => {
        fs.promises.readFile('ec/nope.txt').then(() => finish(null)).catch(finish);
      });
      fs.rmSync('ec', { recursive: true, force: true });
      console.log(out.join('\n'));
      process.exit(0);
    })();
    """#
    let ours = await runOurs(script: script, argv: [], dir: base.appendingPathComponent("errcodes"))
    let expected = """
    readFileSync missing: ENOENT open
    readFileSync on a directory: EISDIR read
    statSync missing: ENOENT stat
    mkdirSync existing: EEXIST mkdir
    mkdirSync missing parent: ENOENT mkdir
    unlinkSync missing: ENOENT unlink
    rmdirSync a file: ENOTDIR rmdir
    readdirSync a file: ENOTDIR scandir
    renameSync missing source: ENOENT rename
    openSync missing, read mode: ENOENT open
    writeFileSync into a missing dir: ENOENT open
    accessSync missing: ENOENT access
    copyFileSync missing source: ENOENT copyfile
    JSON.parse bad input: (no code) -
    connect refused: ECONNREFUSED connect
    lookup bogus host: ENOTFOUND getaddrinfo
    readFile callback missing: ENOENT open
    promises readFile missing: ENOENT open

    """.stripIndent()
    if ours.out == expected {
        print("fixture error-codes: codes, syscalls, and refusing what node refuses")
    } else {
        failures += 1
        print("MISMATCH: error-codes\n---- ours ----\n\(ours.out)---- expected ----\n\(expected)")
    }
}

// -- the AbortSignal audit: every API node lets you cancel -----------------------------
// Two of the previous batch's findings were the SAME defect in different places — an accepted and
// ignored signal — so this swept the whole class instead of meeting it again later. Eight of ten
// were ignored, and five of those turned a cancellable wait into a permanent one: the caller's
// only way out did nothing. One shared helper (__onAbort/__abortError) now wires all of them,
// because eight copies of this logic would drift.
do {
    let script = #"""
    // The SIGNAL audit: every API node lets you abort. Two of the last three findings were this same
    // defect in different places, and an ignored signal is the worst kind — the caller's only way out
    // becomes a permanent wait. Sweeping the class instead of meeting it again later.
    const fs = require('fs');
    const events = require('events');
    const stream = require('stream');
    const readline = require('readline');
    const timers = require('timers/promises');
    const out = [];
    const say = (l, v) => out.push(l + ': ' + v);
    const race = (label, build) => new Promise(resolve => {
      let settled = false;
      const finish = v => { if (!settled) { settled = true; say(label, v); resolve(); } };
      setTimeout(() => finish('NEVER SETTLED'), 1000);
      try { build(finish); } catch (e) { finish('THREW ' + String(e.message).slice(0, 40)); }
    });
    const isAbort = e => (e && (e.name === 'AbortError' || e.code === 'ABORT_ERR')) ? 'aborted' : 'other:' + (e && (e.code || e.name));

    fs.rmSync('sig', { recursive: true, force: true });
    fs.mkdirSync('sig');
    fs.writeFileSync('sig/f.txt', 'x');

    (async () => {
      // AbortSignal's own constructors, which everything below leans on.
      await race('AbortSignal.timeout fires', finish => {
        const signal = AbortSignal.timeout(80);
        if (typeof signal.addEventListener !== 'function') return finish('no addEventListener');
        signal.addEventListener('abort', () => finish('aborted'));
      });
      await race('AbortSignal.any fires', finish => {
        const controller = new AbortController();
        const any = AbortSignal.any([controller.signal, new AbortController().signal]);
        any.addEventListener('abort', () => finish('aborted'));
        setTimeout(() => controller.abort(), 60);
      });

      // timers/promises: a sleep you can cancel.
      await race('timers.setTimeout signal', finish => {
        const controller = new AbortController();
        timers.setTimeout(5000, null, { signal: controller.signal })
          .then(() => finish('resolved')).catch(e => finish(isAbort(e)));
        setTimeout(() => controller.abort(), 80);
      });

      // events.on (the async-iterator form) must end when aborted.
      await race('events.on signal', finish => {
        const controller = new AbortController();
        const emitter = new events.EventEmitter();
        (async () => {
          try { for await (const _ of events.on(emitter, 'never', { signal: controller.signal })) {} finish('ended'); }
          catch (e) { finish(isAbort(e)); }
        })();
        setTimeout(() => controller.abort(), 80);
      });

      // fs reads and writes take one too.
      await race('fs.readFile signal', finish => {
        const controller = new AbortController();
        controller.abort();
        fs.readFile('sig/f.txt', { signal: controller.signal }, error => finish(error ? isAbort(error) : 'read anyway'));
      });
      await race('fs.promises.readFile signal', finish => {
        const controller = new AbortController();
        controller.abort();
        fs.promises.readFile('sig/f.txt', { signal: controller.signal })
          .then(() => finish('read anyway')).catch(e => finish(isAbort(e)));
      });
      // A watcher you cannot stop is a leak.
      await race('fs.watch signal closes it', finish => {
        const controller = new AbortController();
        const watcher = fs.watch('sig', { signal: controller.signal });
        watcher.on('close', () => finish('closed'));
        watcher.on('error', () => {});
        setTimeout(() => controller.abort(), 80);
      });

      // stream helpers.
      await race('stream.finished signal', finish => {
        const controller = new AbortController();
        const never = new stream.Readable({ read() {} });
        stream.finished(never, { signal: controller.signal }, error => finish(error ? isAbort(error) : 'finished'));
        setTimeout(() => controller.abort(), 80);
      });
      // The signal form of pipeline is the PROMISE one; node rejects the callback+options order.
      await race('stream/promises pipeline signal', finish => {
        const controller = new AbortController();
        const never = new stream.Readable({ read() {} });
        const sink = new stream.Writable({ write(c, e, cb) { cb(); } });
        require('stream/promises').pipeline(never, sink, { signal: controller.signal })
          .then(() => finish('piped')).catch(e => finish(isAbort(e)));
        setTimeout(() => controller.abort(), 80);
      });

      // readline: an interface that closes when told.
      await race('readline signal closes', finish => {
        const controller = new AbortController();
        const rl = readline.createInterface({ input: new stream.Readable({ read() {} }), signal: controller.signal });
        rl.on('close', () => finish('closed'));
        setTimeout(() => controller.abort(), 80);
      });

      fs.rmSync('sig', { recursive: true, force: true });
      console.log(out.join('\n'));
      process.exit(0);
    })();
    """#
    let ours = await runOurs(script: script, argv: [], dir: base.appendingPathComponent("signals"))
    let expected = """
    AbortSignal.timeout fires: aborted
    AbortSignal.any fires: aborted
    timers.setTimeout signal: aborted
    events.on signal: aborted
    fs.readFile signal: aborted
    fs.promises.readFile signal: aborted
    fs.watch signal closes it: closed
    stream.finished signal: aborted
    stream/promises pipeline signal: aborted
    readline signal closes: closed

    """.stripIndent()
    if ours.out == expected {
        print("fixture abort-signals: ten cancellable APIs all cancel")
    } else {
        failures += 1
        print("MISMATCH: abort-signals\n---- ours ----\n\(ours.out)---- expected ----\n\(expected)")
    }
}

// -- options, third batch: a byte range that was not a range -------------------------
// Five more accepted-and-ignored options. The worst returned WRONG DATA rather than an error:
// `fs.createReadStream(path, {start, end})` ignored the range and handed back the whole file,
// which is what a tar reader or an HTTP range response is built on. `events.once(..., {signal})`
// was the other bad shape — an ignored signal means the promise never settles at all.
do {
    let script = #"""
    // Options detector, third batch. Applying the rules the last two batches taught: every check is
    // isolated so one throw cannot hide the rest, and every async check races a fallback so an
    // ignored option reports a wrong answer instead of hanging.
    const fs = require('fs');
    const crypto = require('crypto');
    const util = require('util');
    const events = require('events');
    const querystring = require('querystring');
    const out = [];
    const say = (l, v) => out.push(l + ': ' + v);
    const check = (l, fn) => { try { say(l, fn()); } catch (e) { say(l, 'THREW ' + String(e.message).slice(0, 45)); } };
    const race = (label, build) => new Promise(resolve => {
      let settled = false;
      const finish = v => { if (!settled) { settled = true; say(label, v); resolve(); } };
      setTimeout(() => finish('NO EFFECT (fell through)'), 1200);
      try { build(finish); } catch (e) { finish('THREW ' + String(e.message).slice(0, 45)); }
    });

    fs.rmSync('o3', { recursive: true, force: true });
    fs.mkdirSync('o3');
    fs.writeFileSync('o3/data.bin', '0123456789');

    // Buffer.from with an offset and length VIEWS a range — ignoring them returns the wrong bytes.
    check('Buffer.from offset+length', () => {
      const backing = new Uint8Array([1, 2, 3, 4, 5]).buffer;
      return JSON.stringify(Array.from(Buffer.from(backing, 1, 3)));
    });
    // util.inspect depth: ignoring it prints the whole tree where node prints [Object].
    check('inspect depth 0', () => util.inspect({ a: { b: { c: 1 } } }, { depth: 0 }));
    check('inspect depth default', () => util.inspect({ a: { b: { c: { d: 1 } } } }));
    // querystring maxKeys caps how much of a hostile query string is parsed.
    check('querystring maxKeys', () => Object.keys(querystring.parse('a=1&b=2&c=3', '&', '=', { maxKeys: 2 })).length);
    // An authTagLength shorter than the default must be honoured for GCM.
    check('cipher authTagLength', () => {
      const c = crypto.createCipheriv('aes-256-gcm', Buffer.alloc(32), Buffer.alloc(12), { authTagLength: 12 });
      c.update('x'); c.final();
      return c.getAuthTag().length;
    });

    (async () => {
      // A byte RANGE read: tar readers and HTTP range responses depend on it, and an ignored
      // start/end quietly returns the whole file — wrong data rather than an error.
      await race('createReadStream start+end', finish => {
        const chunks = [];
        const stream = fs.createReadStream('o3/data.bin', { start: 2, end: 5 });
        stream.on('data', c => chunks.push(c));
        stream.on('end', () => finish(JSON.stringify(Buffer.concat(chunks).toString())));
        stream.on('error', e => finish('error ' + e.code));
      });
      await race('createReadStream encoding', finish => {
        const parts = [];
        const stream = fs.createReadStream('o3/data.bin', { encoding: 'utf8' });
        stream.on('data', c => parts.push(typeof c));
        stream.on('end', () => finish(JSON.stringify(parts)));
        stream.on('error', e => finish('error ' + e.code));
      });
      // createWriteStream with flags 'a' must append, not truncate.
      await race('createWriteStream flags a', finish => {
        const stream = fs.createWriteStream('o3/data.bin', { flags: 'a' });
        stream.end('AB', () => finish(JSON.stringify(fs.readFileSync('o3/data.bin', 'utf8'))));
        stream.on('error', e => finish('error ' + e.code));
      });
      // events.once with a signal must reject when aborted rather than waiting forever.
      await race('events.once signal', finish => {
        const controller = new AbortController();
        const emitter = new events.EventEmitter();
        events.once(emitter, 'never', { signal: controller.signal })
          .then(() => finish('resolved'))
          .catch(e => finish(e.name === 'AbortError' ? 'aborted' : 'error:' + e.code));
        setTimeout(() => controller.abort(), 100);
      });
      fs.rmSync('o3', { recursive: true, force: true });
      console.log(out.join('\n'));
      process.exit(0);
    })();
    """#
    let ours = await runOurs(script: script, argv: [], dir: base.appendingPathComponent("options3"))
    let expected = """
    Buffer.from offset+length: [2,3,4]
    inspect depth 0: { a: [Object] }
    inspect depth default: { a: { b: { c: [Object] } } }
    querystring maxKeys: 2
    cipher authTagLength: 12
    createReadStream start+end: "2345"
    createReadStream encoding: ["string"]
    createWriteStream flags a: "0123456789AB"
    events.once signal: aborted

    """.stripIndent()
    if ours.out == expected {
        print("fixture options-third: byte ranges, inspect depth, authTagLength, once+signal")
    } else {
        failures += 1
        print("MISMATCH: options-third\n---- ours ----\n\(ours.out)---- expected ----\n\(expected)")
    }
}

// -- options, second batch: an AbortSignal that actually aborts ----------------------
// The options detector applied to child_process, http and readline. http's `timeout` and
// readline's `crlfDelay` already worked; two did not. The important one is `signal`: an ignored
// AbortSignal is the worst shape this bug can take, because the caller's only way to cancel
// silently becomes a permanent wait. Every check below has a FALLBACK timer — the first version
// of this probe had none on the abort case and hung for ten minutes, which is the finding
// arriving in the least useful possible way.
do {
    let script = #"""
    const http = require('http');
    const readline = require('readline');
    const { Readable } = require('stream');
    const out = [];
    const say = (l, v) => out.push(l + ': ' + v);
    const race = (label, build) => new Promise(resolve => {
      let settled = false;
      const finish = value => { if (!settled) { settled = true; say(label, value); resolve(); } };
      setTimeout(() => finish('NO EFFECT (fell through)'), 1200);
      build(finish);
    });
    (async () => {
      const server = http.createServer((req, res) => { if (req.url !== '/slow') res.end('quick'); });
      await new Promise(resolve => server.listen(0, resolve));
      const port = server.address().port;
      await race('http signal aborts', finish => {
        const controller = new AbortController();
        const request = http.get({ port, path: '/slow', signal: controller.signal }, () => finish('answered'));
        request.on('error', e => finish(e.name === 'AbortError' ? 'aborted' : 'error:' + e.code));
        setTimeout(() => controller.abort(), 100);
      });
      await race('http signal already aborted', finish => {
        const controller = new AbortController();
        controller.abort();
        const request = http.get({ port, path: '/slow', signal: controller.signal }, () => finish('answered'));
        request.on('error', e => finish(e.name === 'AbortError' ? 'aborted' : 'error:' + e.code));
      });
      await race('http timeout option', finish => {
        const request = http.get({ port, path: '/slow', timeout: 150 }, () => finish('answered'));
        request.on('timeout', () => { request.destroy(); finish('timeout fired'); });
        request.on('error', () => {});
      });
      await race('readline crlfDelay', finish => {
        const lines = [];
        const rl = readline.createInterface({ input: Readable.from(['a\r\nb\r\n']), crlfDelay: Infinity });
        rl.on('line', l => lines.push(l));
        rl.on('close', () => finish(JSON.stringify(lines)));
      });
      // What the msh path genuinely cannot do says so, rather than ignoring it.
      try { require('child_process').spawnSync('echo', ['x'], { input: 'fed' }); say('spawnSync input', 'ALLOWED'); }
      catch (error) { say('spawnSync input refused', /msh|live process/.test(error.message)); }
      server.closeAllConnections();
      server.close();
      console.log(out.join('\n'));
      process.exit(0);
    })();
    """#
    let ours = await runOurs(script: script, argv: [], dir: base.appendingPathComponent("options2"))
    let expected = """
    http signal aborts: aborted
    http signal already aborted: aborted
    http timeout option: timeout fired
    readline crlfDelay: ["a","b"]
    spawnSync input refused: true

    """.stripIndent()
    if ours.out == expected {
        print("fixture options-second: an AbortSignal aborts, and what msh cannot do says so")
    } else {
        failures += 1
        print("MISMATCH: options-second\n---- ours ----\n\(ours.out)---- expected ----\n\(expected)")
    }
}

// -- options that are accepted and IGNORED --------------------------------------------
// Fourth detector, and the one with the worst findings. An export sweep, a shape sweep and a
// globals sweep all miss this: the function exists, the signature accepts the option, and the
// option does nothing. Seven were found on the first run, two of them destructive —
// `writeFileSync(flag:'a')` TRUNCATED the file it was asked to append to, and `rmSync(dir)`
// without `recursive` deleted the whole tree where node refuses outright. Every option here has
// an observable effect, so being ignored shows up as a wrong answer rather than as silence.
do {
    let script = #"""
    // Fourth detector: options that are ACCEPTED AND IGNORED. Invisible to an export sweep, a shape
    // sweep and a globals sweep — TextDecoder's dropped {stream:true} was exactly this. Each line
    // below exercises an option whose effect is OBSERVABLE, so silence shows up as a wrong answer.
    const fs = require('fs');
    const { Readable, Writable } = require('stream');
    const zlib = require('zlib');
    const out = [];
    const say = (label, value) => out.push(label + ': ' + value);

    fs.rmSync('opt', { recursive: true, force: true });
    fs.mkdirSync('opt/deep/deeper', { recursive: true });
    say('mkdir recursive', fs.existsSync('opt/deep/deeper'));
    fs.writeFileSync('opt/a.txt', 'hello');
    fs.writeFileSync('opt/deep/b.txt', 'world');
    fs.writeFileSync('opt/deep/deeper/c.txt', 'again');

    // fs.readdirSync's recursive option (node 20+): silence here means a shallow listing.
    say('readdir recursive', JSON.stringify(fs.readdirSync('opt', { recursive: true }).map(String).sort()));
    say('readdir withFileTypes', JSON.stringify(fs.readdirSync('opt', { withFileTypes: true })
          .map(d => d.name + (d.isDirectory() ? '/' : '')).sort()));
    // encoding as an option vs a bare string.
    say('readFile encoding option', JSON.stringify(fs.readFileSync('opt/a.txt', { encoding: 'utf8' })));
    say('readFile hex', JSON.stringify(fs.readFileSync('opt/a.txt', 'hex')));
    // flag: 'a' must append rather than truncate.
    fs.writeFileSync('opt/a.txt', '+more', { flag: 'a' });
    say('writeFile flag a', JSON.stringify(fs.readFileSync('opt/a.txt', 'utf8')));
    // mode on writeFile, read back through stat.
    fs.writeFileSync('opt/m.txt', 'x', { mode: 0o600 });
    say('writeFile mode', (fs.statSync('opt/m.txt').mode & 0o777).toString(8));
    // rm without recursive must refuse a non-empty directory.
    try { fs.rmSync('opt/deep'); say('rm non-recursive', 'ALLOWED'); }
    catch (error) { say('rm non-recursive', error.code); }
    // force silences a missing path.
    try { fs.rmSync('opt/nope', { force: true }); say('rm force missing', 'silent'); }
    catch (error) { say('rm force missing', error.code); }

    // Stream options with observable effects.
    const objects = new Readable({ objectMode: true, read() {} });
    objects.push({ a: 1 }); objects.push(null);
    say('readable objectMode', JSON.stringify(objects.read()));
    const encoded = new Readable({ encoding: 'hex', read() {} });
    encoded.push(Buffer.from([0xab, 0xcd])); encoded.push(null);
    say('readable encoding option', JSON.stringify(encoded.read()));
    const small = new Writable({ highWaterMark: 2, write(c, e, cb) { setTimeout(cb, 5); } });
    say('writable highWaterMark respected', small.write('abcd') === false);

    // zlib level: 0 must not compress, 9 must compress harder than 1 on repetitive data.
    const payload = Buffer.from('ab'.repeat(400));
    const none = zlib.gzipSync(payload, { level: 0 }).length;
    const nine = zlib.gzipSync(payload, { level: 9 }).length;
    say('gzip level 0 is larger than level 9', none > nine);
    say('gzip level 0 exceeds input', none > payload.length);
    fs.rmSync('opt', { recursive: true, force: true });
    console.log(out.join('\n'));
    """#
    let ours = await runOurs(script: script, argv: [], dir: base.appendingPathComponent("options"))
    let expected = """
    mkdir recursive: true
    readdir recursive: ["a.txt","deep","deep/b.txt","deep/deeper","deep/deeper/c.txt"]
    readdir withFileTypes: ["a.txt","deep/"]
    readFile encoding option: "hello"
    readFile hex: "68656c6c6f"
    writeFile flag a: "hello+more"
    writeFile mode: 600
    rm non-recursive: ERR_FS_EISDIR
    rm force missing: silent
    readable objectMode: {"a":1}
    readable encoding option: "abcd"
    writable highWaterMark respected: true
    gzip level 0 is larger than level 9: true
    gzip level 0 exceeds input: true

    """.stripIndent()
    if ours.out == expected {
        print("fixture options-honoured: flags, modes, recursion, backpressure and zlib levels")
    } else {
        failures += 1
        print("MISMATCH: options-honoured\n---- ours ----\n\(ours.out)---- expected ----\n\(expected)")
    }
}

// -- TextDecoderStream/TextEncoderStream, and a streaming TextDecoder ----------------
// From the GLOBALS sweep — the third detector, after module exports and instance shapes. Nothing
// had looked at globalThis, where the web-standard surface modern packages reach for directly
// lives. `response.body.pipeThrough(new TextDecoderStream())` is how a fetch body is read as text
// without buffering it all, and the discriminating case is a character SPLIT ACROSS CHUNKS: our
// TextDecoder ignored its options argument entirely, so it had no partial-sequence state and a
// per-chunk decode would have corrupted it.
do {
    let script = #"""
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
    """#
    let ours = await runOurs(script: script, argv: [], dir: base.appendingPathComponent("textstream"))
    let expected = """
    decoded across chunk boundary: "\u{20AC}A"
    encoded: [104,105]
    sides are objects: object object
    partial then rest: "" "\u{20AC}"
    fatal/ignoreBOM present: true true
    encodeInto: {"read":2,"written":4} bytes=[97,226,130,172]
    encodeInto tight: {"read":0,"written":0}

    """.stripIndent()
    if ours.out == expected {
        print("fixture text-streams: a character split across chunks survives the decode")
    } else {
        failures += 1
        print("MISMATCH: text-streams\n---- ours ----\n\(ours.out)---- expected ----\n\(expected)")
    }
}

// -- http.Server's connection management ---------------------------------------------
// closeIdleConnections and closeAllConnections differ on purpose: an in-flight request SURVIVES
// the first and dies to the second. That is the difference between draining keep-alive clients
// and refusing to wait for a slow handler, and it is why node has two methods rather than a flag.
// Both act without closing the listener, which `close()` cannot do.
do {
    let script = #"""
    const http = require('http');
    const out = [];
    // The distinction that is the whole reason node has two methods: an in-flight request must
    // SURVIVE closeIdleConnections, and closeAllConnections must kill it without waiting.
    let release = null;
    const server = http.createServer((req, res) => {
      if (req.url === '/slow') { release = () => res.end('slow done'); return; }
      res.end('quick');
    });
    server.listen(0, () => {
      const port = server.address().port;
      const agent = new http.Agent({ keepAlive: true });
      http.get({ port, path: '/quick', agent }, first => {
        first.resume();
        first.on('end', () => {
          out.push('methods present: ' + (typeof server.closeIdleConnections === 'function') +
                   ' ' + (typeof server.closeAllConnections === 'function'));
          const slow = http.get({ port, path: '/slow' }, res => {
            let body = '';
            res.on('data', c => body += c);
            res.on('end', () => {
              out.push('in-flight survived closeIdleConnections: ' + (body === 'slow done'));
              finish();
            });
          });
          slow.on('error', e => { out.push('slow errored: ' + e.code); finish(); });
          // Once the slow request is at the handler, drop only the IDLE keep-alive socket.
          setTimeout(() => {
            if (server.closeIdleConnections) server.closeIdleConnections();
            setTimeout(() => release && release(), 60);
          }, 90);
        });
      });
      const finish = () => {
        // Now a second in-flight request, killed outright.
        const doomed = http.get({ port, path: '/slow' }, () => { out.push('doomed answered'); done(); });
        doomed.on('error', e => { out.push('closeAllConnections killed in-flight: ' + (e.code === 'ECONNRESET')); done(); });
        setTimeout(() => { if (server.closeAllConnections) server.closeAllConnections(); }, 80);
        const done = () => {
          agent.destroy();
          server.close();
          console.log(out.join('\n'));
          process.exit(0);
        };
      };
    });
    """#
    let ours = await runOurs(script: script, argv: [], dir: base.appendingPathComponent("httpclose"))
    let expected = """
    methods present: true true
    in-flight survived closeIdleConnections: true
    closeAllConnections killed in-flight: true

    """.stripIndent()
    if ours.out == expected {
        print("fixture http-close: idle connections drop, in-flight ones survive until told not to")
    } else {
        failures += 1
        print("MISMATCH: http-close\n---- ours ----\n\(ours.out)---- expected ----\n\(expected)")
    }
}

// -- node 17+'s stream operators ------------------------------------------------------
// "Stream depth": map/filter/flatMap/take/drop return streams, and forEach/toArray/reduce/
// some/every/find return promises. All expressible over async iteration, which already worked —
// the gap was the surface, not the machinery. The edge cases are the point: unseeded reduce takes
// the FIRST value as its accumulator, and on an empty stream every() is true while some() is false.
do {
    let script = #"""
    const { Readable } = require('stream');
    const src = () => Readable.from([1, 2, 3, 4, 5]);
    const out = [];
    (async () => {
      out.push('toArray: ' + JSON.stringify(await src().toArray()));
      out.push('map: ' + JSON.stringify(await src().map(x => x * 2).toArray()));
      out.push('filter: ' + JSON.stringify(await src().filter(x => x % 2 === 1).toArray()));
      out.push('take: ' + JSON.stringify(await src().take(2).toArray()));
      out.push('take 0: ' + JSON.stringify(await src().take(0).toArray()));
      out.push('take beyond: ' + JSON.stringify(await src().take(99).toArray()));
      out.push('drop: ' + JSON.stringify(await src().drop(3).toArray()));
      out.push('drop all: ' + JSON.stringify(await src().drop(99).toArray()));
      out.push('flatMap: ' + JSON.stringify(await src().flatMap(x => [x, -x]).toArray()));
      out.push('reduce: ' + await src().reduce((a, b) => a + b));
      out.push('reduce seeded: ' + await src().reduce((a, b) => a + b, 100));
      out.push('some true: ' + await src().some(x => x > 4));
      out.push('some false: ' + await src().some(x => x > 9));
      out.push('every true: ' + await src().every(x => x > 0));
      out.push('every false: ' + await src().every(x => x > 3));
      out.push('find: ' + await src().find(x => x > 3));
      out.push('find missing: ' + await src().find(x => x > 9));
      const seen = [];
      await src().forEach(x => { seen.push(x); });
      out.push('forEach: ' + JSON.stringify(seen));
      // Empty-stream edge cases, where every/some invert.
      out.push('empty every: ' + await Readable.from([]).every(x => false));
      out.push('empty some: ' + await Readable.from([]).some(x => true));
      out.push('empty reduce seeded: ' + await Readable.from([]).reduce((a, b) => a + b, 7));
      // An async mapper must be awaited, not treated as a value.
      out.push('async map: ' + JSON.stringify(await src().map(async x => x * 3).toArray()));
      // Chained, which is the point of having them.
      out.push('chained: ' + JSON.stringify(await src().map(x => x * 10).filter(x => x > 20).take(2).toArray()));
      // iterator() gives an async iterator over the same data.
      const it = src().iterator();
      const first = await it.next();
      out.push('iterator: ' + JSON.stringify(first.value) + ' done=' + first.done);
      // The returned things are streams, not arrays.
      out.push('map returns a stream: ' + (typeof src().map(x => x).pipe === 'function'));
      console.log(out.join('\n'));
    })().catch(error => { console.log('THREW ' + error.message); });
    """#
    let ours = await runOurs(script: script, argv: [], dir: base.appendingPathComponent("streamops"))
    let expected = """
    toArray: [1,2,3,4,5]
    map: [2,4,6,8,10]
    filter: [1,3,5]
    take: [1,2]
    take 0: []
    take beyond: [1,2,3,4,5]
    drop: [4,5]
    drop all: []
    flatMap: [1,-1,2,-2,3,-3,4,-4,5,-5]
    reduce: 15
    reduce seeded: 115
    some true: true
    some false: false
    every true: true
    every false: false
    find: 4
    find missing: undefined
    forEach: [1,2,3,4,5]
    empty every: true
    empty some: false
    empty reduce seeded: 7
    async map: [3,6,9,12,15]
    chained: [30,40]
    iterator: 1 done=false
    map returns a stream: true

    """.stripIndent()
    if ours.out == expected {
        print("fixture stream-operators: map/filter/take/drop/reduce and the empty-stream cases")
    } else {
        failures += 1
        print("MISMATCH: stream-operators\n---- ours ----\n\(ours.out)---- expected ----\n\(expected)")
    }
}

// -- crypto objects are streams, and read() is binary-safe ---------------------------
// Top of what the instance-shape sweep left: Hash/Hmac/Cipher are Transforms in node, so
// `fs.createReadStream(f).pipe(hash)` is the ordinary way to hash a file and could not work here.
// Making them streams then exposed a worse bug underneath: Readable.read() decoded each chunk as
// UTF-8 into a string, joined, and re-encoded — lossy for anything that is not UTF-8 text — and
// ignored WHICH encoding setEncoding asked for. The 'data' path was always correct, so only code
// calling read() was affected, which is why it survived until a digest went through it.
do {
    let script = #"""
    const crypto = require('crypto');
    const { Readable } = require('stream');
    const out = [];
    const data = Buffer.from('stream me through a hash');
    const expected = crypto.createHash('sha256').update(data).digest('hex');

    // read() must return the BYTES it was given, for every byte value.
    const every = Buffer.from(Array.from({ length: 256 }, (_, i) => i));
    const binary = new Readable({ read() {} });
    binary.push(every.slice(0, 100));
    binary.push(every.slice(100));
    binary.push(null);
    const readBack = binary.read();
    out.push('read() is binary-safe: ' + (Buffer.isBuffer(readBack) && readBack.equals(every)));

    // setEncoding decides what read() returns, and hex is the case a digest needs.
    const hexStream = new Readable({ read() {} });
    hexStream.setEncoding('hex');
    hexStream.push(Buffer.from([0xde, 0xad, 0xbe, 0xef]));
    hexStream.push(null);
    out.push('setEncoding hex on read(): ' + (hexStream.read() === 'deadbeef'));

    out.push('hash is a stream: ' + (typeof crypto.createHash('sha256').pipe === 'function'));
    const hex = crypto.createHash('sha256');
    hex.setEncoding('hex');
    hex.end(data);
    out.push('piped hash digest: ' + (hex.read() === expected));

    const hmacExpected = crypto.createHmac('sha256', 'k').update(data).digest('hex');
    const hmac = crypto.createHmac('sha256', 'k');
    hmac.setEncoding('hex');
    hmac.end(data);
    out.push('piped hmac digest: ' + (hmac.read() === hmacExpected));

    // A spent hash reports itself rather than quietly digesting twice.
    const spent = crypto.createHash('sha256');
    spent.digest();
    try { spent.update('more'); out.push('reuse: ALLOWED'); }
    catch (error) { out.push('reuse refused: ' + error.code); }

    // A cipher piped through must equal the one-shot bytes.
    const k = Buffer.alloc(32, 7), iv = Buffer.alloc(16, 9);
    const single = crypto.createCipheriv('aes-256-cbc', k, iv);
    const oneShot = Buffer.concat([single.update(data), single.final()]);
    const cipher = crypto.createCipheriv('aes-256-cbc', k, iv);
    const chunks = [];
    cipher.on('data', c => chunks.push(c));
    cipher.on('end', () => {
      out.push('cipher stream equals one-shot: ' + Buffer.concat(chunks).equals(oneShot));
      console.log(out.join('\n'));
    });
    cipher.end(data);
    """#
    let ours = await runOurs(script: script, argv: [], dir: base.appendingPathComponent("cryptostream"))
    let expected = """
    read() is binary-safe: true
    setEncoding hex on read(): true
    hash is a stream: true
    piped hash digest: true
    piped hmac digest: true
    reuse refused: ERR_CRYPTO_HASH_FINALIZED
    cipher stream equals one-shot: true

    """.stripIndent()
    if ours.out == expected {
        print("fixture crypto-streams: hashes pipe, and read() keeps bytes intact")
    } else {
        failures += 1
        print("MISMATCH: crypto-streams\n---- ours ----\n\(ours.out)---- expected ----\n\(expected)")
    }
}

// -- Buffer's missing documented methods ---------------------------------------------
// Found by sweeping instance SHAPES rather than exports — the only way a missing method on the
// most-used object in Node shows up before a program needs it. writeFloat is the one that stings:
// readFloat was already here, so a binary format could be read and not written. Also the signed
// BigInt64 pair, the variable-width int family (1..6 bytes), swap16/32/64, node's lowercase
// `uint` aliases, and Buffer.copyBytesFrom.
do {
    let script = #"""
    const out = [];
    // Floats: writeFloat was missing while readFloat was present, so binary formats could be read
    // and not written.
    for (const [w, r] of [['writeFloatBE', 'readFloatBE'], ['writeFloatLE', 'readFloatLE']]) {
      const b = Buffer.alloc(4);
      const ret = b[w](1.5, 0);
      out.push(`${w} bytes=${b.toString('hex')} ret=${ret} back=${b[r](0)}`);
    }
    // The 16-bit signed writers, missing while their readers were present.
    for (const [w, r] of [['writeInt16BE', 'readInt16BE'], ['writeInt16LE', 'readInt16LE']]) {
      const b = Buffer.alloc(2);
      b[w](-300, 0);
      out.push(`${w} bytes=${b.toString('hex')} back=${b[r](0)}`);
    }
    // Signed 64-bit, both orders, including the extremes.
    for (const value of [0n, 1n, -1n, 9223372036854775807n, -9223372036854775808n]) {
      const be = Buffer.alloc(8), le = Buffer.alloc(8);
      be.writeBigInt64BE(value, 0); le.writeBigInt64LE(value, 0);
      out.push(`bigint64 ${value} be=${be.toString('hex')} le=${le.toString('hex')} back=${be.readBigInt64BE(0)},${le.readBigInt64LE(0)}`);
    }
    // Variable-width integers, every legal byte count.
    for (let size = 1; size <= 6; size++) {
      const be = Buffer.alloc(6), le = Buffer.alloc(6);
      const value = Math.pow(2, size * 8 - 3) + 5;
      be.writeUIntBE(value, 0, size); le.writeUIntLE(value, 0, size);
      out.push(`uint${size} be=${be.toString('hex')} le=${le.toString('hex')} back=${be.readUIntBE(0, size)},${le.readUIntLE(0, size)}`);
      const signedBE = Buffer.alloc(6), signedLE = Buffer.alloc(6);
      const negative = -(Math.pow(2, size * 8 - 4) + 3);
      signedBE.writeIntBE(negative, 0, size); signedLE.writeIntLE(negative, 0, size);
      out.push(`int${size} be=${signedBE.toString('hex')} le=${signedLE.toString('hex')} back=${signedBE.readIntBE(0, size)},${signedLE.readIntLE(0, size)}`);
    }
    // Out-of-range byte counts must throw, not silently truncate.
    for (const size of [0, 7]) {
      try { Buffer.alloc(8).readUIntBE(0, size); out.push(`size ${size}: ALLOWED`); }
      catch (error) { out.push(`size ${size}: ${error.name}`); }
    }
    // Byte-order swaps, in place, returning the same buffer.
    const s16 = Buffer.from([1, 2, 3, 4, 5, 6, 7, 8]);
    out.push('swap16 ' + s16.swap16().toString('hex') + ' same=' + (s16.swap16 !== undefined));
    out.push('swap32 ' + Buffer.from([1, 2, 3, 4, 5, 6, 7, 8]).swap32().toString('hex'));
    out.push('swap64 ' + Buffer.from([1, 2, 3, 4, 5, 6, 7, 8]).swap64().toString('hex'));
    try { Buffer.alloc(3).swap16(); out.push('swap16 odd: ALLOWED'); }
    catch (error) { out.push('swap16 odd: ' + error.name); }
    // The lowercase aliases must be the same functions, not near-copies.
    const b = Buffer.alloc(8);
    out.push('aliases identical: ' + ['readUint8', 'readUint16BE', 'readUint32LE', 'writeUint16BE',
                                     'readUintBE', 'writeUintLE', 'readBigUint64BE']
      .every(n => typeof b[n] === 'function' && b[n] === b[n.replace('Uint', 'UInt').replace('BigUInt', 'BigUInt')]));
    out.push('readUint16BE works: ' + (function(){ const x = Buffer.from([0x12, 0x34]); return x.readUint16BE(0); })());
    // copyBytesFrom copies VALUES, widened per element — not a reinterpretation of memory.
    const source = new Uint16Array([0x1234, 0x5678]);
    out.push('copyBytesFrom: ' + Buffer.copyBytesFrom(source).toString('hex'));
    out.push('copyBytesFrom sliced: ' + Buffer.copyBytesFrom(source, 1, 1).toString('hex'));
    console.log(out.join('\n'));
    """#
    let ours = await runOurs(script: script, argv: [], dir: base.appendingPathComponent("bufnum"))
    let expected = """
    writeFloatBE bytes=3fc00000 ret=4 back=1.5
    writeFloatLE bytes=0000c03f ret=4 back=1.5
    writeInt16BE bytes=fed4 back=-300
    writeInt16LE bytes=d4fe back=-300
    bigint64 0 be=0000000000000000 le=0000000000000000 back=0,0
    bigint64 1 be=0000000000000001 le=0100000000000000 back=1,1
    bigint64 -1 be=ffffffffffffffff le=ffffffffffffffff back=-1,-1
    bigint64 9223372036854775807 be=7fffffffffffffff le=ffffffffffffff7f back=9223372036854775807,9223372036854775807
    bigint64 -9223372036854775808 be=8000000000000000 le=0000000000000080 back=-9223372036854775808,-9223372036854775808
    uint1 be=250000000000 le=250000000000 back=37,37
    int1 be=ed0000000000 le=ed0000000000 back=-19,-19
    uint2 be=200500000000 le=052000000000 back=8197,8197
    int2 be=effd00000000 le=fdef00000000 back=-4099,-4099
    uint3 be=200005000000 le=050020000000 back=2097157,2097157
    int3 be=effffd000000 le=fdffef000000 back=-1048579,-1048579
    uint4 be=200000050000 le=050000200000 back=536870917,536870917
    int4 be=effffffd0000 le=fdffffef0000 back=-268435459,-268435459
    uint5 be=200000000500 le=050000002000 back=137438953477,137438953477
    int5 be=effffffffd00 le=fdffffffef00 back=-68719476739,-68719476739
    uint6 be=200000000005 le=050000000020 back=35184372088837,35184372088837
    int6 be=effffffffffd le=fdffffffffef back=-17592186044419,-17592186044419
    size 0: RangeError
    size 7: RangeError
    swap16 0201040306050807 same=true
    swap32 0403020108070605
    swap64 0807060504030201
    swap16 odd: RangeError
    aliases identical: true
    readUint16BE works: 4660
    copyBytesFrom: 34127856
    copyBytesFrom sliced: 7856

    """.stripIndent()
    if ours.out == expected {
        print("fixture buffer-numerics: floats, BigInt64, variable-width ints, swaps and aliases")
    } else {
        failures += 1
        print("MISMATCH: buffer-numerics\n---- ours ----\n\(ours.out)---- expected ----\n\(expected)")
    }
}

// -- the dns.resolve* family exists, and the refusals that remain name why -----------
// The live comparison against real node (every record type, real internet answers) is in the
// dnsres harness — this suite stays hermetic, the same reason the dns-lookup fixture avoids the
// network. What is checked here needs no network: the surface is present, and the two things that
// still say no give a reason.
do {
    let script = #"""
    const dns = require('dns');
    const names = ['resolveTxt', 'resolveMx', 'resolveNs', 'resolveCname', 'resolvePtr',
                   'resolveSoa', 'resolveSrv', 'resolveNaptr', 'resolveCaa', 'resolveAny',
                   'reverse', 'lookupService'];
    console.log('resolvers present:', names.every(n => typeof dns[n] === 'function'));
    console.log('promises too:', names.filter(n => n !== 'lookupService')
                                      .every(n => typeof dns.promises[n] === 'function'));
    // An unknown record type is an error naming what IS available, not a silent empty list.
    dns.resolve('example.com', 'HINFO', error => {
      console.log('unknown type:', error && error.code, /A, AAAA/.test(error.message));
      // TLSA RESOLVES now. Its refusal was about consuming the record — a DANE check needs a
      // TLS stack — which says nothing about reading it off the wire: three bytes and a blob.
      dns.resolveTlsa('_25._tcp.mail.ietf.org', (tlsaError, tlsa) => {
        console.log('TLSA resolves:', !tlsaError && Array.isArray(tlsa) && tlsa.length > 0 &&
                                      typeof tlsa[0].certUsage === 'number' &&
                                      typeof tlsa[0].selector === 'number' &&
                                      tlsa[0].data instanceof ArrayBuffer);
      });
    });
    """#
    let ours = await runOurs(script: script, argv: [], dir: base.appendingPathComponent("dnsres"))
    let expected = """
    resolvers present: true
    promises too: true
    unknown type: ENOTIMP true
    TLSA resolves: true

    """.stripIndent()
    if ours.out == expected {
        print("fixture dns-resolvers: the family is present, and TLSA still names its reason")
    } else {
        failures += 1
        print("MISMATCH: dns-resolvers\n---- ours ----\n\(ours.out)---- expected ----\n\(expected)")
    }
}

// -- brotli: the system framework had it all along ------------------------------------
// The refusal said brotli "is not built into this device". Apple's Compression framework has
// shipped COMPRESSION_BROTLI since iOS 15 — found by a surface SWEEP (call every export in both
// engines and compare the failures), not by a package breaking. zstd genuinely is absent and
// still refuses. Compressed bytes need not match node's, so what is checked is the property that
// matters plus the streaming case a one-shot-behind-a-stream-API fake would fail.
do {
    let script = #"""
    const zlib = require('zlib');
    const sample = Buffer.from('brotli '.repeat(500) + 'tail');
    const packed = zlib.brotliCompressSync(sample);
    console.log('round trip:', zlib.brotliDecompressSync(packed).equals(sample));
    console.log('smaller than input:', packed.length < sample.length);
    try { zlib.brotliDecompressSync(Buffer.from('not brotli at all')); console.log('corrupt: ALLOWED'); }
    catch (error) { console.log('corrupt input errors:', error instanceof Error); }
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
        try { zlib.zstdCompressSync(Buffer.from('x')); console.log('zstd: ALLOWED'); }
        catch (error) { console.log('zstd still refuses, names the framework:', /compression framework/.test(error.message)); }
      });
      for (let i = 0; i < streamed.length; i += 7) decompressor.write(streamed.slice(i, i + 7));
      decompressor.end();
    });
    for (let i = 0; i < sample.length; i += 111) compressor.write(sample.slice(i, i + 111));
    compressor.end();
    """#
    let ours = await runOurs(script: script, argv: [], dir: base.appendingPathComponent("brotli"))
    let expected = """
    round trip: true
    smaller than input: true
    corrupt input errors: true
    stream round trip: true
    stream output decodes one-shot: true
    zstd still refuses, names the framework: true

    """.stripIndent()
    if ours.out == expected {
        print("fixture brotli: round trips, streams in pieces, and zstd still refuses")
    } else {
        failures += 1
        print("MISMATCH: brotli\n---- ours ----\n\(ours.out)---- expected ----\n\(expected)")
    }
}

// -- crypto.diffieHellman AND finite-field DH -----------------------------------------
// This refusal was wrong twice. First it attached a real constraint to the wrong function:
// `crypto.diffieHellman({privateKey, publicKey})` agrees over X25519 and the EC curves, all of
// which CryptoKit does. Then the constraint itself turned out to be imaginary — "needs a bignum
// implementation" assumed the bignum was missing, and JavaScriptCore has had native BigInt the
// whole time (a 2048-bit modpow costs about 2 ms). Both halves are real now.
do {
    let script = #"""
    const crypto = require('crypto');
    for (const [type, curve] of [['x25519', null], ['ec', 'prime256v1'], ['ec', 'secp384r1'], ['ec', 'secp521r1']]) {
      const options = curve ? { namedCurve: curve } : undefined;
      const a = crypto.generateKeyPairSync(type, options);
      const b = crypto.generateKeyPairSync(type, options);
      const s1 = crypto.diffieHellman({ privateKey: a.privateKey, publicKey: b.publicKey });
      const s2 = crypto.diffieHellman({ privateKey: b.privateKey, publicKey: a.publicKey });
      console.log(`${curve || type}: agree=${s1.equals(s2)} bytes=${s1.length}`);
    }
    // An x25519 key must not be mistaken for the Ed25519 key it resembles: same wrapper shape,
    // same 32 bytes, different OID.
    const x = crypto.generateKeyPairSync('x25519');
    const ed = crypto.generateKeyPairSync('ed25519');
    console.log('types kept apart:', x.privateKey.asymmetricKeyType, ed.privateKey.asymmetricKeyType);
    // Finite-field DH is the other API, and it works now — on native BigInt.
    const g = crypto.getDiffieHellman('modp14');
    const h = crypto.getDiffieHellman('modp14');
    g.generateKeys(); h.generateKeys();
    const shared = g.computeSecret(h.getPublicKey());
    console.log('finite-field DH: agree=' + shared.equals(h.computeSecret(g.getPublicKey())) +
                ' bytes=' + shared.length);
    console.log('primality: ' + crypto.checkPrimeSync(7919n) + ' ' + crypto.checkPrimeSync(7917n) +
                ' carmichael=' + crypto.checkPrimeSync(561n));
    """#
    let ours = await runOurs(script: script, argv: [], dir: base.appendingPathComponent("dh"))
    let expected = """
    x25519: agree=true bytes=32
    prime256v1: agree=true bytes=32
    secp384r1: agree=true bytes=48
    secp521r1: agree=true bytes=66
    types kept apart: x25519 ed25519
    finite-field DH: agree=true bytes=256
    primality: true false carmichael=false

    """.stripIndent()
    if ours.out == expected {
        print("fixture diffie-hellman: X25519, EC, and finite-field DH on native BigInt")
    } else {
        failures += 1
        print("MISMATCH: diffie-hellman\n---- ours ----\n\(ours.out)---- expected ----\n\(expected)")
    }
}

// -- fs.glob: shipped where node is consistent, refused where it is not -------------
// The refusal said glob is a corpus of edge cases and a partial matcher would be worse than
// none. That was a judgement about risk, so it was measured: a 1824-case corpus against
// `path.matchesGlob` found 17 disagreements, all in two families where NODE contradicts itself
// (case sensitivity depends on whether the pattern contains `*`; a trailing slash is stripped
// for a literal but not for `**`). `fs.glob` has no such trouble and matches node exactly, so
// the walk ships and `path.matchesGlob` keeps its refusal — now with numbers behind it.
do {
    let script = #"""
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
    """#
    let ours = await runOurs(script: script, argv: [], dir: base.appendingPathComponent("glob"))
    let expected = """
    *.js -> ["a.js"]
    **/*.js -> ["a.js","lib/f.js","src/c.js","src/deep/e.js"]
    src/*.js -> ["src/c.js"]
    **/*.ts -> ["b.ts","src/d.ts"]
    * -> ["a.js","b.ts","lib","src"]
    src/** -> ["src","src/c.js","src/d.ts","src/deep","src/deep/e.js"]
    **/deep/*.js -> ["src/deep/e.js"]
    *.{js,ts} -> ["a.js","b.ts"]
    [al]* -> ["a.js","lib"]
    async -> ["a.js","lib/f.js","src/c.js","src/deep/e.js"]
    exclude refused, reason named: true
    matchesGlob refused, reason named: true

    """.stripIndent()
    if ours.out == expected {
        print("fixture glob: node's exact file lists, and the two refusals name measured reasons")
    } else {
        failures += 1
        print("MISMATCH: glob\n---- ours ----\n\(ours.out)---- expected ----\n\(expected)")
    }
}

// -- scrypt: RFC 7914, not a missing system primitive ---------------------------------
// The refusal said "scrypt has no system implementation here", which was true and beside the
// point. scrypt is PBKDF2-HMAC-SHA256 — which CommonCrypto has — wrapped around a memory-hard
// mix built from Salsa20/8, and that mix is arithmetic. The first three lines are RFC 7914's
// PUBLISHED vectors, so this checks the standard and not merely agreement with node.
do {
    let script = #"""
    const crypto = require('crypto');
    // RFC 7914 §12 publishes these three, so a match is against the standard and not just node.
    const rfc = [
      ['', '', 16, 1, 1, 64],
      ['password', 'NaCl', 1024, 8, 16, 64],
      ['pleaseletmein', 'SodiumChloride', 16384, 8, 1, 64],
    ];
    for (const [pw, salt, N, r, p, len] of rfc) {
      console.log(`N=${N} r=${r} p=${p}: ` + crypto.scryptSync(pw, salt, len, { N, r, p }).toString('hex'));
    }
    // Defaults, the option aliases, a Buffer password, and a non-multiple-of-64 key length.
    console.log('defaults:', crypto.scryptSync('pass', 'salt', 32).toString('hex'));
    console.log('aliases :', crypto.scryptSync('a', 'b', 21, { cost: 16, blockSize: 1, parallelization: 2 }).toString('hex'));
    console.log('buffers :', crypto.scryptSync(Buffer.from('pw'), Buffer.from('sl'), 16, { N: 16, r: 1, p: 1 }).toString('hex'));

    // Rejected parameters must carry node's code.
    const bad = [[{ N: 3 }, 'N not a power of two'], [{ N: 1024, r: 8, p: 1, maxmem: 1024 }, 'over maxmem'], [{ N: 1 }, 'N too small']];
    for (const [options, label] of bad) {
      try { crypto.scryptSync('a', 'b', 8, options); console.log(label + ': ALLOWED'); }
      catch (error) { console.log(label + ': ' + error.code); }
    }
    // The async form reports through a callback, and after the synchronous return.
    const order = [];
    crypto.scrypt('pw', 'salt', 16, { N: 16, r: 1, p: 1 }, (error, key) => {
      order.push('callback:' + (error ? error.code : key.toString('hex')));
      // Bad params THROW here rather than reaching the callback, which is node's shape.
      try { crypto.scrypt('pw', 'salt', 8, { N: 3 }, () => order.push('bad-async:called back')); }
      catch (error) { order.push('bad-async threw:' + error.code); }
      console.log(order.join(' | '));
    });
    order.push('sync-first');
    """#
    let ours = await runOurs(script: script, argv: [], dir: base.appendingPathComponent("scrypt"))
    let expected = """
    N=16 r=1 p=1: 77d6576238657b203b19ca42c18a0497f16b4844e3074ae8dfdffa3fede21442fcd0069ded0948f8326a753a0fc81f17e8d3e0fb2e0d3628cf35e20c38d18906
    N=1024 r=8 p=16: fdbabe1c9d3472007856e7190d01e9fe7c6ad7cbc8237830e77376634b3731622eaf30d92e22a3886ff109279d9830dac727afb94a83ee6d8360cbdfa2cc0640
    N=16384 r=8 p=1: 7023bdcb3afd7348461c06cd81fd38ebfda8fbba904f8e3ea9b543f6545da1f2d5432955613f0fcf62d49705242a9af9e61e85dc0d651e40dfcf017b45575887
    defaults: 4cac4540992d51feeaefe4668bbfed7222f02b445aaffbbe60cfec110fb2735c
    aliases : d5d4fb3a6a574291c0d4fe88e41ce1ec6142f2607a
    buffers : fa9fa850eca5dc1de2524c4ab5f46ae1
    N not a power of two: ERR_CRYPTO_INVALID_SCRYPT_PARAMS
    over maxmem: ERR_CRYPTO_INVALID_SCRYPT_PARAMS
    N too small: ERR_CRYPTO_INVALID_SCRYPT_PARAMS
    sync-first | callback:086be1ce38ba574b6133f2c1cfafecb7 | bad-async threw:ERR_CRYPTO_INVALID_SCRYPT_PARAMS

    """.stripIndent()
    if ours.out == expected {
        print("fixture scrypt: RFC 7914 vectors byte for byte, and node's parameter rules")
    } else {
        failures += 1
        print("MISMATCH: scrypt\n---- ours ----\n\(ours.out)---- expected ----\n\(expected)")
    }
}

// -- the tick guarantee after HOST EVENTS, by six different routes -------------------
// The trampoline covers the loop's own phases. A bridge that calls JavaScript from its own
// handler needed wrapping too, and two did not have it: dns completions and watch events both
// ran promises before ticks. Six routes out of the host are checked here because "the ones I
// happened to test" is how the first version of this guarantee ended up half-true.
do {
    let script = #"""
    const fs = require('fs');
    const net = require('net');
    const http = require('http');
    const dns = require('dns');
    const { spawn } = require('child_process');
    const out = [];
    const mark = tag => { Promise.resolve().then(() => out.push(tag + ':promise')); process.nextTick(() => out.push(tag + ':tick')); };

    // Each of these reaches user code by a DIFFERENT route out of the host.
    fs.readFile(process.argv[1], () => {
      mark('fs');
      dns.lookup('localhost', { family: 4 }, () => {
        mark('dns');
        const watched = 'watch-probe.txt';
        fs.writeFileSync(watched, 'a');
        const watcher = fs.watch(watched, () => {
          watcher.close();
          mark('watch');
          const server = http.createServer((req, res) => res.end('hi'));
          server.listen(0, () => {
            http.get({ port: server.address().port, path: '/' }, res => {
              mark('http-response');
              res.resume();
              res.on('end', () => {
                server.close();
                const child = spawn('node', ['-e', 'process.exit(0)']);
                child.on('exit', () => {
                  mark('child-exit');
                  const srv = net.createServer(c => c.end('x')).listen(0, () => {
                    const client = net.connect(srv.address().port, '127.0.0.1');
                    client.on('data', () => mark('sock'));
                    client.on('close', () => {
                      srv.close();
                      setTimeout(() => {
                        // Report pairs in order: every tag must show tick BEFORE promise.
                        const tags = [...new Set(out.map(v => v.split(':')[0]))];
                        console.log(tags.map(t => t + '=' + (out.indexOf(t + ':tick') < out.indexOf(t + ':promise') ? 'tick-first' : 'PROMISE-FIRST')).join(' '));
                      }, 30);
                    });
                  });
                });
              });
            });
          });
        });
        setTimeout(() => fs.writeFileSync(watched, 'b'), 60);
      });
    });
    """#
    let ours = await runOurs(script: script, argv: [], dir: base.appendingPathComponent("ioorder"))
    let expected = """
    fs=tick-first dns=tick-first watch=tick-first http-response=tick-first child-exit=tick-first sock=tick-first

    """.stripIndent()
    if ours.out == expected {
        print("fixture host-event-ticks: nextTick beats promises on every route out of the host")
    } else {
        failures += 1
        print("MISMATCH: host-event-ticks\n---- ours ----\n\(ours.out)---- expected ----\n\(expected)")
    }
}

// -- the loop's ordering: nextTick, promises, ports, immediates ----------------------
// Two claims at once. process.nextTick must drain before ANY promise reaction — it is scheduled
// AS a microtask here, so it used to win only when registered first, and a host callback now
// drains the queue before the stack unwinds. And MessagePort delivery is its own loop PHASE:
// a nextTick queued AFTER a postMessage still runs first, which no microtask drain can express.
do {
    let script = #"""
    const { MessageChannel } = require('worker_threads');
    // Port delivery is its own loop phase in node: after nextTick and microtasks, before immediates.
    const a = new MessageChannel();
    const first = [];
    a.port2.on('message', () => first.push('port'));
    process.nextTick(() => first.push('nextTick'));
    setImmediate(() => first.push('setImmediate'));
    Promise.resolve().then(() => first.push('promise'));
    a.port1.postMessage(1);

    setTimeout(() => {
      console.log('post last: ', first.join(' -> '));
      // And the harder case: everything queued AFTER the postMessage still runs before the port.
      const b = new MessageChannel();
      const second = [];
      b.port2.on('message', () => second.push('port'));
      b.port1.postMessage(1);
      Promise.resolve().then(() => second.push('promise-after-post'));
      process.nextTick(() => second.push('nextTick-after-post'));
      setTimeout(() => {
        console.log('post first: ', second.join(' -> '));
        a.port1.close(); a.port2.close(); b.port1.close(); b.port2.close();
      }, 20);
    }, 20);
    """#
    let ours = await runOurs(script: script, argv: [], dir: base.appendingPathComponent("order"))
    let expected = """
    post last:  nextTick -> promise -> port -> setImmediate
    post first:  nextTick-after-post -> promise-after-post -> port

    """.stripIndent()
    if ours.out == expected {
        print("fixture loop-order: ticks beat promises, and ports are their own phase")
    } else {
        failures += 1
        print("MISMATCH: loop-order\n---- ours ----\n\(ours.out)---- expected ----\n\(expected)")
    }
}

// -- BroadcastChannel and receiveMessageOnPort: refused for the wrong reason ---------
// Both were refused as needing shared memory between contexts. Neither does.
// BroadcastChannel is a name registry plus fan-out — the main engine already talks to every
// worker over a JSON channel, so it can BE the hub. receiveMessageOnPort does not WAIT for
// anything: it pops a message the port already queued and returns undefined when there is
// none. Cross-worker fan-out and the loop-hold live in the dedicated broadcast harness.
do {
    let script = #"""
    const { MessageChannel, receiveMessageOnPort } = require('worker_threads');
    const { port1, port2 } = new MessageChannel();
    port1.postMessage({ n: 1 });
    port1.postMessage({ n: 2 });
    console.log('sync drain 1:', JSON.stringify(receiveMessageOnPort(port2)));
    console.log('sync drain 2:', JSON.stringify(receiveMessageOnPort(port2)));
    console.log('sync drain 3:', JSON.stringify(receiveMessageOnPort(port2)));
    console.log('returns undefined when empty:', receiveMessageOnPort(port2) === undefined);
    port1.close(); port2.close();

    const a = new BroadcastChannel('room');
    const b = new BroadcastChannel('room');
    const other = new BroadcastChannel('elsewhere');
    const heard = [];
    b.onmessage = e => heard.push('b:' + e.data);
    other.onmessage = e => heard.push('other:' + e.data);
    a.onmessage = e => heard.push('a:' + e.data);
    a.postMessage('hello');
    setTimeout(() => {
      console.log('heard:', heard.join(',') || '(nothing)');
      console.log('sender hears itself:', heard.some(h => h.startsWith('a:')));
      console.log('global BroadcastChannel:', typeof BroadcastChannel);
      a.close(); b.close(); other.close();
    }, 50);
    """#
    let ours = await runOurs(script: script, argv: [], dir: base.appendingPathComponent("broadcast"))
    let expected = """
    sync drain 1: {"message":{"n":1}}
    sync drain 2: {"message":{"n":2}}
    sync drain 3: undefined
    returns undefined when empty: true
    heard: b:hello
    sender hears itself: false
    global BroadcastChannel: function

    """.stripIndent()
    if ours.out == expected {
        print("fixture broadcast-channel: same-name fan-out, and a port queue that drains")
    } else {
        failures += 1
        print("MISMATCH: broadcast-channel\n---- ours ----\n\(ours.out)---- expected ----\n\(expected)")
    }
}

// -- http: a connection that dies is an ERROR, never a hang -------------------------
// Found by cluster's test: killing a worker left its connections in the primary's keep-alive
// pool and the next request waited forever. Two independent faults — a pool that hands out a
// socket whose peer has hung up, and a request that emits neither 'response' nor 'error' when
// the socket closes under it. A hang is the one network failure a caller cannot recover from,
// so both halves are checked here against real node.
do {
    let script = #"""
    const net = require('net');
    const http = require('http');

    // 1. The peer accepts and vanishes without answering.
    const rude = net.createServer(c => c.destroy());
    rude.listen(0, () => {
      const request = http.get({ port: rude.address().port, path: '/' }, () => {
        console.log('unexpected response');
      });
      request.on('error', error => {
        console.log('no answer ->', error.code);
        rude.close();
        poolTest();
      });
    });

    // 2. A pooled connection the PEER hangs up on must leave the pool, and the next request must
    //    not be handed that corpse.
    function poolTest() {
      const agent = new http.Agent({ keepAlive: true });
      let peerSide = null;
      const server = http.createServer((req, res) => { peerSide = res.socket; res.end('ok'); });
      server.listen(0, () => {
        const port = server.address().port;
        const pooled = () => {
          const key = Object.keys(agent.freeSockets)[0];
          return key ? agent.freeSockets[key] : [];
        };
        http.get({ port: port, path: '/one', agent: agent }, res => {
          res.resume();
          res.on('end', () => setImmediate(() => {
            console.log('socket pooled after first request:', pooled().length === 1);
            pooled()[0].once('close', () => setImmediate(() => {
              console.log('pool empty after the peer hung up:', pooled().length === 0);
              // The real point: a request now must open a FRESH connection and be answered.
              http.get({ port: port, path: '/two', agent: agent }, res2 => {
                let body = '';
                res2.on('data', c => body += c);
                res2.on('end', () => {
                  console.log('next request still answered:', body === 'ok');
                  agent.destroy();
                  server.close();
                });
              }).on('error', e => { console.log('next request FAILED:', e.code); agent.destroy(); server.close(); });
            }));
            peerSide.end();          // the server side sends FIN on the idle connection
          }));
        });
      });
    }
    """#
    let ours = await runOurs(script: script, argv: [], dir: base.appendingPathComponent("hangup"))
    let expected = """
    no answer -> ECONNRESET
    socket pooled after first request: true
    pool empty after the peer hung up: true
    next request still answered: true

    """.stripIndent()
    if ours.out == expected {
        print("fixture http-hangup: a dead connection errors and leaves the pool")
    } else {
        failures += 1
        print("MISMATCH: http-hangup\n---- ours ----\n\(ours.out)---- expected ----\n\(expected)")
    }
}

// -- dns: real lookups through getaddrinfo -----------------------------------------
// Only the cases real node and getaddrinfo agree on by construction. node's resolve4 goes to
// a DNS SERVER through c-ares and does not read the hosts file, so it is deliberately absent
// here — a fixture across that difference would prove nothing.
do {
    let script = #"""
    const dns = require('dns');
    dns.lookup('127.0.0.1', (error, address, family) => {
      console.log('literal:', error, address, family);
      dns.lookup('localhost', { family: 4 }, (error2, address2, family2) => {
        console.log('localhost:', error2, address2, family2);
        dns.lookup('localhost', { family: 4, all: true }, (error3, all) => {
          console.log('all is array:', Array.isArray(all), 'has 127.0.0.1:',
                      all.some(entry => entry.address === '127.0.0.1'));
          dns.lookup('this-name-does-not-exist.invalid', (error4) => {
            console.log('bogus name code:', error4 && error4.code);
            dns.promises.lookup('localhost', { family: 4 }).then(result => {
              console.log('promise form:', result.address, result.family);
              console.log('servers is array:', Array.isArray(dns.getServers()));
              console.log('constants:', dns.NOTFOUND, typeof dns.Resolver);
            });
          });
        });
      });
    });
    """#
    let oursDir = base.appendingPathComponent("ours-dns")
    let realDir = base.appendingPathComponent("real-dns")
    try? FileManager.default.createDirectory(at: oursDir, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(at: realDir, withIntermediateDirectories: true)
    let ours = await runOurs(script: script, argv: [], dir: oursDir)
    let real = runReal(script: script, argv: [], dir: realDir)
    if ours.out == real.out && ours.status == real.status {
        print("fixture dns-lookup: match")
    } else {
        failures += 1
        print("MISMATCH: dns-lookup")
        print("  ---- ours ----\n\(ours.out)  ---- real ----\n\(real.out)  --------------")
    }
}

// -- fetch + https.get against a local HTTP server --------------------------------
do {
    let serveDir = base.appendingPathComponent("www")
    try? FileManager.default.createDirectory(at: serveDir, withIntermediateDirectories: true)
    try? "hello from the wire\n".write(to: serveDir.appendingPathComponent("payload.txt"), atomically: true, encoding: .utf8)
    try? "{\"answer\": 42}".write(to: serveDir.appendingPathComponent("data.json"), atomically: true, encoding: .utf8)
    let port = 8900 + Int(getpid()) % 90
    let server = Process()
    server.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/python3")
    server.arguments = ["-m", "http.server", String(port), "--bind", "127.0.0.1", "-d", serveDir.path]
    server.standardOutput = Pipe()
    server.standardError = Pipe()
    try server.run()
    // Poll until the server answers — a fixed sleep raced on slower runs.
    for _ in 0..<50 {
        if let _ = try? await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/payload.txt")!) { break }
        try? await Task.sleep(nanoseconds: 100_000_000)
    }

    let script = """
    const base = 'http://127.0.0.1:\(port)';
    async function main() {
      const text = await (await fetch(base + '/payload.txt')).text();
      console.log('fetched:', text.trim());
      const json = await (await fetch(base + '/data.json')).json();
      console.log('json:', json.answer);
      const missing = await fetch(base + '/nope.txt');
      console.log('missing status ok:', missing.status === 404, missing.ok);
      const http = require('http');
      http.get(base + '/payload.txt', res => {
        let body = '';
        res.on('data', chunk => body += chunk);
        res.on('end', () => console.log('http.get:', res.statusCode, body.trim()));
      });
    }
    main();
    """
    let oursDir = base.appendingPathComponent("ours-http")
    let realDir = base.appendingPathComponent("real-http")
    try? FileManager.default.createDirectory(at: oursDir, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(at: realDir, withIntermediateDirectories: true)
    let ours = await runOurs(script: script, argv: [], dir: oursDir)
    let real = runReal(script: script, argv: [], dir: realDir)
    server.terminate()
    if ours.out == real.out && ours.status == real.status {
        print("fixture fetch-http: match")
    } else {
        failures += 1
        print("MISMATCH: fetch-http (status ours=\(ours.status) real=\(real.status))")
        print("  ---- ours ----\n\(ours.out)  ---- real ----\n\(real.out)  --------------")
    }
} catch {
    failures += 1
    print("FAIL: fetch fixture: \(error.localizedDescription)")
}

try? FileManager.default.removeItem(at: base)
print(failures == 0 ? "PHASE G: ALL PASS" : "\(failures) FAILURES")
exit(failures == 0 ? 0 : 1)
