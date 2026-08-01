import Foundation
setvbuf(stdout, nil, _IONBF, 0)

// `const { debuglog } = require('node:util')` — a core module's functions travel alone all the
// time, and one that reaches through `this` is broken the moment they do. It cost fastify its
// boot (through avvio) and, a few boundaries earlier, eslint its timings. That is a SHAPE, so
// this looks for the shape rather than for the two instances of it.
//
// Two passes. The dynamic one destructures the functions people actually destructure and calls
// them unbound — the real failure, reproduced. The static one reads every core module's own
// functions and flags any whose body reaches through `this` BEFORE it nests a function of its
// own, which is where an unbound call breaks; a `this` inside a RETURNED function is forwarding
// the caller's, which is correct, and promisify and callbackify both do it.

let base = FileManager.default.temporaryDirectory.appendingPathComponent("unbound-\(getpid())")
try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
try? "x".write(to: base.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)

let script = #"""
const ESC = String.fromCharCode(27);
const calls = [
  ['util', 'debuglog', (f) => typeof f('probe') === 'function'],
  ['util', 'format', (f) => f('%s-%d', 'a', 1) === 'a-1'],
  ['util', 'inspect', (f) => f({ a: 1 }) === '{ a: 1 }'],
  ['util', 'promisify', (f) => typeof f((cb) => cb(null, 1)) === 'function'],
  ['util', 'callbackify', (f) => typeof f(async () => 1) === 'function'],
  ['util', 'deprecate', (f) => typeof f(() => 1, 'x') === 'function'],
  ['util', 'inherits', (f) => { function A(){}; function B(){}; f(B, A); return B.super_ === A; }],
  ['util', 'isDeepStrictEqual', (f) => f({ a: [1] }, { a: [1] })],
  ['util', 'stripVTControlCharacters', (f) => f(ESC + '[32mx' + ESC + '[39m') === 'x'],
  ['crypto', 'randomUUID', (f) => f().length === 36],
  ['crypto', 'createHash', (f) => f('sha256').update('a').digest('hex').length === 64],
  ['crypto', 'randomBytes', (f) => f(8).length === 8],
  ['crypto', 'generateKeySync', (f) => f('hmac', { length: 256 }).type === 'secret'],
  ['crypto', 'timingSafeEqual', (f) => f(Buffer.from('ab'), Buffer.from('ab'))],
  ['path', 'join', (f) => f('/a', 'b') === '/a/b'],
  ['path', 'resolve', (f) => f('/a', 'b') === '/a/b'],
  ['path', 'relative', (f) => f('/a/b', '/a/c') === '../c'],
  ['fs', 'existsSync', (f) => f('/file.txt')],
  ['fs', 'readFileSync', (f) => f('/file.txt', 'utf8') === 'x'],
  ['os', 'tmpdir', (f) => typeof f() === 'string'],
  ['url', 'pathToFileURL', (f) => f('/a').href === 'file:///a'],
  ['url', 'fileURLToPath', (f) => f('file:///a') === '/a'],
  ['querystring', 'stringify', (f) => f({ a: 1 }) === 'a=1'],
  ['querystring', 'parse', (f) => f('a=1').a === '1'],
  ['events', 'once', (f) => typeof f === 'function'],
  ['stream', 'pipeline', (f) => typeof f === 'function'],
  ['zlib', 'gzipSync', (f) => f(Buffer.from('x')).length > 0],
  ['assert', 'deepStrictEqual', (f) => { f({ a: 1 }, { a: 1 }); return true; }],
  ['timers', 'setImmediate', (f) => typeof f === 'function'],
];
let broken = 0;
for (const [moduleName, name, check] of calls) {
  const loose = require(moduleName)[name];
  if (typeof loose !== 'function') { broken++; console.log('MISSING', moduleName + '.' + name); continue; }
  try {
    if (check(loose) !== true) { broken++; console.log('WRONG', moduleName + '.' + name); }
  } catch (error) {
    broken++;
    console.log('THREW', moduleName + '.' + name, '-', String(error.message).slice(0, 70));
  }
}
console.log('unbound calls broken:', broken, 'of', calls.length);

// The static sweep, over every core module this engine has.
const modules = ['assert', 'buffer', 'child_process', 'cluster', 'console', 'crypto',
  'dgram', 'diagnostics_channel', 'dns', 'events', 'fs', 'http', 'https', 'module', 'net',
  'os', 'path', 'perf_hooks', 'process', 'punycode', 'querystring', 'readline', 'stream',
  'string_decoder', 'timers', 'tls', 'tty', 'url', 'util', 'v8', 'vm', 'worker_threads', 'zlib'];
const suspects = [];
for (const moduleName of modules) {
  let module;
  try { module = require(moduleName); } catch (error) { continue; }
  for (const key of Object.getOwnPropertyNames(module)) {
    const descriptor = Object.getOwnPropertyDescriptor(module, key);
    if (!descriptor || descriptor.get) continue;          // a getter's `this` IS the module
    const value = descriptor.value;
    if (typeof value !== 'function') continue;
    if (/^[A-Z]/.test(key)) continue;                     // a constructor's `this` is its instance
    // …and so is a constructor exported under a lowercase name: `events.default` IS
    // EventEmitter. A prototype carrying methods is what makes something a constructor.
    if (value.prototype && Object.getOwnPropertyNames(value.prototype).length > 1) continue;
    let body;
    try { body = Function.prototype.toString.call(value); } catch (error) { continue; }
    if (body.indexOf('[native code]') >= 0) continue;
    const open = body.indexOf('{');
    if (open < 0) continue;
    const nested = body.slice(open + 1).search(/function\b|=>/);
    const head = nested < 0 ? body.slice(open + 1) : body.slice(open + 1, open + 1 + nested);
    if (/\bthis\s*[.\[]/.test(head)) suspects.push(moduleName + '.' + key);
  }
}
console.log('static suspects:', suspects.length ? suspects.join(', ') : 'none');
"""#

let engine = NodeEngine(root: base, env: ["PATH": "/", "HOME": "/"])
let result = await engine.run(source: script, path: "/probe.cjs", argv: ["node", "/probe.cjs"], cwd: "/", stdin: "")
print(result.out)
if !result.err.isEmpty { print("stderr: \(result.err.prefix(600))") }

if result.out.contains("unbound calls broken: 0 of"), result.out.contains("static suspects: none") {
    print("UNBOUND MATCH — every core function people destructure works alone, and no core module "
          + "reaches through `this` before it nests")
} else {
    print("MISMATCH: a core module function depends on its receiver")
    exit(1)
}
try? FileManager.default.removeItem(at: base)
