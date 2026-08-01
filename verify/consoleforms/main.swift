import Foundation
setvbuf(stdout, nil, _IONBF, 0)

// What the user READS. In an editor the console is the whole debugging surface, and a format
// specifier that renders the wrong thing — or a `%j` that throws on a cycle, or a table that is
// not a table — is a defect the reader carries. util.format is what console.log runs on, so it
// is swept with it.

let realNode = "/Users/thyfriendlyfox/.local/bin/node"
let base = FileManager.default.temporaryDirectory.appendingPathComponent("consoleforms-\(getpid())")
try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

let script = #"""
const util = require('util');

// util.format's specifiers, which is what console.log runs on.
const cases = [
  ['%s and %d', 'one', 2],
  ['%s', { a: 1 }],
  ['%s', Symbol('tag')],
  ['%d', '42'],
  ['%d', 'not a number'],
  ['%i', '42.9'],
  ['%f', '42.9'],
  ['%j', { a: [1, 2] }],
  ['%j', { self: null }],
  ['%o', { a: { b: { c: 1 } } }],
  ['%O', { a: { b: { c: 1 } } }],
  ['%%', 'unused'],
  ['%c styled', 'color: red'],
  ['no specifiers', 'extra', 3, { k: 1 }],
  ['%s', undefined],
  ['%s', null],
  ['%s %s', 'only one'],
  ['%d %i %f', 1.5, 1.5, 1.5],
  ['%j', 1n],
];
for (const [format, ...args] of cases) {
  try { console.log('format ' + JSON.stringify(format) + ' -> ' + JSON.stringify(util.format(format, ...args))); }
  // The MESSAGE of a JSON.stringify failure belongs to the JavaScript engine underneath — V8
  // and JavaScriptCore word it differently — so what is compared is that it threw, and its type.
  catch (error) { console.log('format ' + JSON.stringify(format) + ' -> THREW ' + error.constructor.name); }
}

// Values without a format string, which is the common case.
for (const value of [1, 'text', true, null, undefined, [1, 2], { a: 1 }, new Map([['k', 1]]),
                     new Set([1]), new Date(0), /re/g, () => {}, Buffer.from('ab'),
                     new Error('boom'), { nested: { deep: { deeper: { deepest: 1 } } } }]) {
  let rendered;
  try { rendered = util.format(value); } catch (error) { rendered = 'THREW'; }
  // An Error renders with its stack, which is a path and line numbers; keep the first line.
  console.log('value -> ' + JSON.stringify(rendered.split('\n')[0]));
}

// util.inspect's options, which console.dir exposes.
console.log('inspect depth 0 -> ' + util.inspect({ a: { b: 1 } }, { depth: 0 }));
console.log('inspect breakLength -> ' + JSON.stringify(util.inspect({ a: 1, b: 2 }, { breakLength: 1 })));
console.log('inspect compact false -> ' + JSON.stringify(util.inspect([1, 2], { compact: false })));
console.log('inspect showHidden array -> ' + util.inspect([1, 2], { showHidden: false }));
console.log('inspect maxArrayLength -> ' + util.inspect([1, 2, 3, 4], { maxArrayLength: 2 }));
console.log('inspect getters -> ' + util.inspect({ get x() { return 1; } }));
console.log('inspect circular -> ' + util.inspect((() => { const o = { a: 1 }; o.self = o; return o; })()));
console.log('inspect a class instance -> ' + util.inspect(new (class Thing { constructor() { this.a = 1; } })()));
console.log('inspect null prototype -> ' + util.inspect(Object.assign(Object.create(null), { a: 1 })));

// console's own surface, captured through the methods that write structure.
console.group('outer');
console.log('inside group');
console.groupEnd();
console.count('tick');
console.count('tick');
console.countReset('tick');
console.count('tick');
console.assert(true, 'never shown');
console.dir({ a: { b: { c: 1 } } }, { depth: 0 });
console.table([{ a: 1, b: 'x' }, { a: 2, b: 'y' }]);
console.log('methods -> ' + JSON.stringify(['debug', 'info', 'warn', 'error', 'trace', 'table',
  'group', 'groupCollapsed', 'groupEnd', 'count', 'countReset', 'time', 'timeEnd', 'timeLog',
  'dir', 'assert', 'clear'].map((name) => typeof console[name])));
"""#

try? script.write(to: base.appendingPathComponent("probe.cjs"), atomically: true, encoding: .utf8)
let process = Process()
process.executableURL = URL(fileURLWithPath: realNode)
process.arguments = ["probe.cjs"]
process.currentDirectoryURL = base
let out = Pipe(), err = Pipe()
process.standardOutput = out
process.standardError = err
try? process.run()
let realText = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
let realProblems = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
process.waitUntilExit()
if !realProblems.isEmpty { print("real stderr: \(realProblems.prefix(300))") }

let engine = NodeEngine(root: base, env: ["PATH": "/"])
let ours = await engine.run(source: script, path: "/probe.cjs", argv: ["node", "/probe.cjs"], cwd: "/", stdin: "")
if !ours.err.isEmpty { print("ours stderr: \(ours.err.prefix(400))") }

let theirs = realText.components(separatedBy: "\n").filter { !$0.isEmpty }
let mine = ours.out.components(separatedBy: "\n").filter { !$0.isEmpty }
var differences: [String] = []
for (index, line) in theirs.enumerated() {
    let ourLine = index < mine.count ? mine[index] : "(missing)"
    if ourLine != line { differences.append("  ours: \(ourLine)\n  node: \(line)") }
}
for extra in mine.dropFirst(theirs.count) { differences.append("  ours said extra: \(extra)") }

if differences.isEmpty, !theirs.isEmpty {
    print("CONSOLE MATCH — all \(theirs.count) lines render exactly as node renders them")
} else {
    print(differences.prefix(14).joined(separator: "\n"))
    print("MISMATCH: \(differences.count) of \(theirs.count)")
    exit(1)
}
try? FileManager.default.removeItem(at: base)
