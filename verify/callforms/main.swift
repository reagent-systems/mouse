import Foundation
setvbuf(stdout, nil, _IONBF, 0)

// The overload sweep, in the territory where the forms are ASYNC and so easier to get half
// right: a stream's three-argument write, Readable.from's several sources, events' argument
// carrying, timers/promises' values, crypto's encodings, and the four shapes of listen().
// Same method as the last one, which found four defects in twenty-two calls.

let realNode = "/Users/thyfriendlyfox/.local/bin/node"
let base = FileManager.default.temporaryDirectory.appendingPathComponent("callforms-\(getpid())")
let realDir = base.appendingPathComponent("real"), ourDir = base.appendingPathComponent("ours")
for directory in [realDir, ourDir] {
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
}

let script = #"""
const { Readable, Writable, PassThrough, pipeline } = require('stream');
const { EventEmitter, once } = require('events');
const timers = require('timers/promises');
const crypto = require('crypto');
const util = require('util');
const net = require('net');
const http = require('http');

const results = [];
function record(label, value) { results.push(label + ' -> ' + JSON.stringify(value)); }
async function check(label, run) {
  try { record(label, await run()); }
  catch (error) { record(label, 'THREW ' + String(error.message).slice(0, 60)); }
}

(async () => {
  // --- Writable's three-argument forms ---
  await check('write(chunk, encoding, cb)', () => new Promise((resolve) => {
    const seen = [];
    const sink = new Writable({ write(chunk, encoding, done) { seen.push([chunk.toString(), encoding]); done(); } });
    sink.write('68690a', 'hex', () => resolve(seen[0]));
  }));
  await check('end(chunk, encoding, cb)', () => new Promise((resolve) => {
    const seen = [];
    const sink = new Writable({ write(chunk, encoding, done) { seen.push(chunk.toString()); done(); } });
    sink.end('bye', 'utf8', () => resolve(seen));
  }));
  await check('setDefaultEncoding', () => new Promise((resolve) => {
    const seen = [];
    const sink = new Writable({ write(chunk, encoding, done) { seen.push(encoding); done(); } });
    sink.setDefaultEncoding('base64');
    sink.write('aGk=', undefined, () => resolve(seen));
  }));

  // --- Readable's shapes ---
  await check('Readable.from an array', async () => {
    const chunks = [];
    for await (const chunk of Readable.from(['a', 'b'])) chunks.push(chunk);
    return chunks;
  });
  await check('Readable.from an async generator', async () => {
    async function* source() { yield 'x'; yield 'y'; }
    const chunks = [];
    for await (const chunk of Readable.from(source())) chunks.push(chunk);
    return chunks;
  });
  await check('read(size) then read()', () => new Promise((resolve) => {
    const stream = new PassThrough();
    stream.write('abcdef');
    stream.end();
    stream.once('readable', () => {
      const first = stream.read(2);
      const rest = stream.read();
      resolve([first && first.toString(), rest && rest.toString()]);
    });
  }));
  await check('setEncoding gives strings', () => new Promise((resolve) => {
    const stream = new PassThrough();
    stream.setEncoding('utf8');
    stream.on('data', (chunk) => resolve([typeof chunk, chunk]));
    stream.end('text');
  }));
  await check('pipeline with a callback', () => new Promise((resolve) => {
    const chunks = [];
    pipeline(Readable.from(['p', 'q']), new Writable({ write(c, e, d) { chunks.push(c.toString()); d(); } }),
             (error) => resolve(error ? 'ERR' : chunks));
  }));

  // --- events ---
  await check('once(emitter, name) resolves with all args', async () => {
    const emitter = new EventEmitter();
    setTimeout(() => emitter.emit('ping', 1, 2), 1);
    return await once(emitter, 'ping');
  });
  await check('prependListener order', () => {
    const emitter = new EventEmitter();
    const order = [];
    emitter.on('go', () => order.push('second'));
    emitter.prependListener('go', () => order.push('first'));
    emitter.emit('go');
    return order;
  });
  await check('listenerCount and rawListeners', () => {
    const emitter = new EventEmitter();
    const handler = () => {};
    emitter.once('x', handler);
    return [emitter.listenerCount('x'), emitter.rawListeners('x').length, emitter.eventNames()];
  });

  // --- timers/promises ---
  await check('timers.setTimeout(ms, value)', async () => await timers.setTimeout(1, 'carried'));
  await check('timers.setImmediate(value)', async () => await timers.setImmediate('now'));

  // --- crypto argument forms ---
  await check('createHash update encoding', () =>
    crypto.createHash('sha256').update('6869', 'hex').digest('hex').slice(0, 8));
  await check('randomInt(min, max)', () => {
    const value = crypto.randomInt(10, 20);
    return [value >= 10 && value < 20, typeof value];
  });
  await check('timingSafeEqual length mismatch', () => {
    try { crypto.timingSafeEqual(Buffer.from('ab'), Buffer.from('abc')); return 'no error'; }
    catch (error) { return error.code || 'threw'; }
  });

  // --- util ---
  await check('promisify custom symbol', async () => {
    function legacy(callback) { callback(null, 'plain'); }
    legacy[util.promisify.custom] = async () => 'custom';
    return await util.promisify(legacy)();
  });
  await check('inspect depth option', () =>
    util.inspect({ a: { b: { c: { d: 1 } } } }, { depth: 1 }));

  // --- listen()'s several shapes ---
  await check('listen(0) then address()', () => new Promise((resolve) => {
    const server = net.createServer();
    server.listen(0, '127.0.0.1', () => {
      const address = server.address();
      server.close(() => resolve([typeof address.port, address.family, address.address]));
    });
  }));
  await check('listen({ port, host })', () => new Promise((resolve) => {
    const server = http.createServer();
    server.listen({ port: 0, host: '127.0.0.1' }, () => {
      const address = server.address();
      server.close(() => resolve(typeof address.port === 'number'));
    });
  }));

  console.log(results.join('\n'));
})();
"""#

for directory in [realDir, ourDir] {
    try? script.write(to: directory.appendingPathComponent("probe.cjs"), atomically: true, encoding: .utf8)
}

let process = Process()
process.executableURL = URL(fileURLWithPath: realNode)
process.arguments = ["probe.cjs"]
process.currentDirectoryURL = realDir
let out = Pipe(), err = Pipe()
process.standardOutput = out
process.standardError = err
try? process.run()
let realText = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
let realProblems = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
process.waitUntilExit()
if !realProblems.isEmpty { print("real stderr: \(realProblems.prefix(400))") }

let engine = NodeEngine(root: ourDir, env: ["PATH": "/"])
let ours = await engine.run(source: script, path: "/probe.cjs", argv: ["node", "/probe.cjs"], cwd: "/", stdin: "")
if !ours.err.isEmpty { print("ours stderr: \(ours.err.prefix(600))") }

let theirs = realText.components(separatedBy: "\n").filter { !$0.isEmpty }
let mine = ours.out.components(separatedBy: "\n").filter { !$0.isEmpty }
var differences = 0
for (index, line) in theirs.enumerated() {
    let ourLine = index < mine.count ? mine[index] : "(missing)"
    if ourLine != line {
        differences += 1
        print("DIFFERS\n  ours: \(ourLine)\n  node: \(line)")
    }
}
if mine.count > theirs.count { differences += mine.count - theirs.count }

if differences == 0, !theirs.isEmpty {
    print("CALL FORM MATCH — all \(theirs.count) asynchronous call forms behave as node's")
} else {
    print("MISMATCH: \(differences) of \(theirs.count) call forms")
    exit(1)
}
try? FileManager.default.removeItem(at: base)
