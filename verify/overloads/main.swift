import Foundation
setvbuf(stdout, nil, _IONBF, 0)

// node's API is a pile of OVERLOADS, and an engine that implements one spelling of each looks
// complete until a package uses the other. The fs boundary found three that way — a numeric
// flag, a numeric `flag` option, and writeSync's two argument orders — so this sweeps the same
// shape across the surfaces a program touches most: extra arguments forwarded to a callback,
// options objects where positional arguments are also allowed, and the overloads on Buffer.

let realNode = "/Users/thyfriendlyfox/.local/bin/node"
let base = FileManager.default.temporaryDirectory.appendingPathComponent("overloads-\(getpid())")
let realDir = base.appendingPathComponent("real"), ourDir = base.appendingPathComponent("ours")
for directory in [realDir, ourDir] {
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
}

let script = #"""
const fs = require('fs');
const path = require('path');
const { Buffer } = require('buffer');

const results = [];
function check(label, run) {
  try { results.push(label + ' -> ' + JSON.stringify(run())); }
  catch (error) { results.push(label + ' -> THREW ' + String(error.message).slice(0, 60)); }
}
function checkAsync(label, run) {
  return new Promise((resolve) => {
    let settled = false;
    const done = (value) => { if (!settled) { settled = true; results.push(label + ' -> ' + JSON.stringify(value)); resolve(); } };
    try { run(done); } catch (error) { done('THREW ' + String(error.message).slice(0, 60)); }
    setTimeout(() => done('TIMED OUT'), 1500);
  });
}

fs.writeFileSync('sample.txt', 'abcdefghij');

// --- extra arguments that are forwarded to a callback ---
(async () => {
  await checkAsync('setTimeout extra args', (done) => setTimeout((a, b) => done([a, b]), 1, 'x', 2));
  await checkAsync('setImmediate extra args', (done) => setImmediate((a, b) => done([a, b]), 'y', 3));
  await checkAsync('nextTick extra args', (done) => process.nextTick((a, b) => done([a, b]), 'z', 4));
  await checkAsync('setInterval extra args', (done) => {
    const timer = setInterval((a) => { clearInterval(timer); done(a); }, 1, 'w');
  });

  // --- fs read/write overloads ---
  check('readSync positional', () => {
    const fd = fs.openSync('sample.txt', 'r');
    const buffer = Buffer.alloc(4);
    const count = fs.readSync(fd, buffer, 0, 4, 2);
    fs.closeSync(fd);
    return [count, buffer.toString()];
  });
  check('readSync options object', () => {
    const fd = fs.openSync('sample.txt', 'r');
    const buffer = Buffer.alloc(4);
    const count = fs.readSync(fd, buffer, { position: 4, length: 3, offset: 1 });
    fs.closeSync(fd);
    return [count, buffer.toString('utf8', 0, 4)];
  });
  await checkAsync('read with an options object', (done) => {
    const fd = fs.openSync('sample.txt', 'r');
    const buffer = Buffer.alloc(4);
    fs.read(fd, buffer, { position: 1, length: 2, offset: 0 }, (error, count) => {
      fs.closeSync(fd);
      done(error ? 'ERR ' + error.code : [count, buffer.toString('utf8', 0, 2)]);
    });
  });

  // --- options that arrive as a string instead of an object ---
  check('readFileSync encoding string', () => fs.readFileSync('sample.txt', 'utf8').length);
  check('readFileSync options object', () => fs.readFileSync('sample.txt', { encoding: 'utf8' }).length);
  check('readdirSync withFileTypes', () => {
    const entries = fs.readdirSync('.', { withFileTypes: true });
    const found = entries.find((entry) => entry.name === 'sample.txt');
    return [typeof found.isFile, found.isFile(), found.isDirectory()];
  });
  check('mkdirSync recursive returns', () => {
    const made = fs.mkdirSync('deep/deeper', { recursive: true });
    return typeof made === 'string' ? 'first path' : String(made);
  });

  // --- Buffer overloads ---
  check('Buffer.alloc fill+encoding', () => Buffer.alloc(6, 'ab', 'utf8').toString());
  check('Buffer.from string+encoding', () => Buffer.from('6869', 'hex').toString());
  check('Buffer.concat with a length', () => Buffer.concat([Buffer.from('ab'), Buffer.from('cd')], 3).toString());
  check('buffer.toString range', () => Buffer.from('abcdef').toString('utf8', 1, 4));
  check('buffer.write offset+length', () => {
    const buffer = Buffer.alloc(6, 0x2e);
    buffer.write('xyz', 2, 2);
    return buffer.toString();
  });

  // --- path and url shapes ---
  check('path.join with dots', () => path.join('a', '..', 'b', './c'));
  check('path.resolve multiple', () => path.resolve('/one', 'two', '../three'));
  check('path.format', () => path.format({ dir: '/a/b', name: 'c', ext: '.js' }));
  check('path.parse', () => { const p = path.parse('/a/b/c.js'); return [p.dir, p.base, p.name, p.ext]; });

  // --- timers/promises and event shapes ---
  check('AbortSignal.timeout exists', () => typeof AbortSignal.timeout === 'function');
  await checkAsync('setTimeout returns a Timeout object', (done) => {
    const timer = setTimeout(() => done([typeof timer.refresh, typeof timer.unref, typeof timer.hasRef]), 1);
  });

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
    print("OVERLOAD MATCH — all \(theirs.count) call forms behave as node's, including the ones "
          + "with a second spelling nobody reaches for first")
} else {
    print("MISMATCH: \(differences) of \(theirs.count) call forms")
    exit(1)
}
try? FileManager.default.removeItem(at: base)
