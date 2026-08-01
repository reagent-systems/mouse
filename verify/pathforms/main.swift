import Foundation
setvbuf(stdout, nil, _IONBF, 0)

// `path` is touched by every tool that reads a file, and it had no gate of its own — the parts
// with a gate were the ones some package had already broken. This is the whole surface at once,
// on the inputs that are actually hard: trailing slashes, doubled separators, dot segments that
// walk past the root, a basename whose extension IS the name, and format's precedence rules.

let realNode = "/Users/thyfriendlyfox/.local/bin/node"
let base = FileManager.default.temporaryDirectory.appendingPathComponent("pathforms-\(getpid())")
try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

let script = #"""
const path = require('path');
const out = [];
function show(label, run) {
  try { out.push(label + ' -> ' + JSON.stringify(run())); }
  catch (error) { out.push(label + ' -> THREW ' + String(error.message).slice(0, 50)); }
}

// join: the separators and the dots
for (const args of [
  ['a', 'b'], ['/a', 'b'], ['a/', '/b'], ['a', '..', 'b'], ['a', '../..', 'b'],
  ['', 'a'], ['a', ''], [''], ['/'], ['.', 'a'], ['a', '.'], ['a', './b'],
  ['a//b', 'c'], ['a', 'b/'], ['/a/b/..'], ['..', 'a'], ['../a', '../b'],
]) show('join ' + JSON.stringify(args), () => path.join(...args));

// resolve: absolute wins, and the cwd is the base
for (const args of [
  ['/a', 'b'], ['/a', '/b'], ['a', 'b'], ['/a/b', '../c'], ['/a', ''], ['/'], ['/a/'],
  ['/a', '.'], ['/a', './b/../c'],
]) show('resolve ' + JSON.stringify(args), () => {
  // Only a LEADING cwd is normalised: this engine's cwd is "/", and a blind replace would eat
  // the leading slash of every absolute answer and invent a difference that is not there.
  const resolved = path.resolve(...args);
  const cwd = process.cwd();
  if (cwd !== '/') return resolved.startsWith(cwd) ? '<cwd>' + resolved.slice(cwd.length) : resolved;
  return args.some((piece) => piece.startsWith('/')) ? resolved : '<cwd>' + resolved;
});

// normalize, relative, dirname, basename, extname
for (const input of ['/a/b/../c', 'a/b/../..', '../a', '/..', '//a//b//', 'a/./b', '', '.', '..', '/a/b/']) {
  show('normalize ' + JSON.stringify(input), () => path.normalize(input));
}
for (const pair of [['/a/b', '/a/c'], ['/a/b', '/a/b'], ['/a', '/a/b/c'], ['/a/b/c', '/a'],
                    ['/a/b', '/c/d'], ['a/b', 'a/c']]) {
  show('relative ' + JSON.stringify(pair), () => path.relative(pair[0], pair[1]));
}
for (const input of ['/a/b/c.txt', '/a/b/', 'c.txt', '/', '', 'a/b', '.hidden', 'a/.hidden',
                     'a.b.c', 'a.', '.', '..', '/a/b/.', 'file.tar.gz']) {
  show('dirname ' + JSON.stringify(input), () => path.dirname(input));
  show('basename ' + JSON.stringify(input), () => path.basename(input));
  show('extname ' + JSON.stringify(input), () => path.extname(input));
}
show('basename with ext', () => path.basename('/a/b/c.txt', '.txt'));
show('basename ext not matching', () => path.basename('/a/b/c.txt', '.md'));
show('basename ext is whole name', () => path.basename('/a/.txt', '.txt'));

// parse / format round trip
for (const input of ['/a/b/c.txt', 'c.txt', '/', 'a/b/', '.hidden', '/a/.hidden.md']) {
  show('parse ' + JSON.stringify(input), () => { const p = path.parse(input); return [p.root, p.dir, p.base, p.name, p.ext]; });
  show('format(parse) ' + JSON.stringify(input), () => path.format(path.parse(input)));
}
show('format dir wins over root', () => path.format({ root: '/ignored/', dir: '/a', base: 'b.txt' }));
show('format base wins over name+ext', () => path.format({ dir: '/a', base: 'b.txt', name: 'x', ext: '.y' }));
show('format name+ext', () => path.format({ dir: '/a', name: 'b', ext: '.txt' }));
show('format ext without dot', () => path.format({ dir: '/a', name: 'b', ext: 'txt' }));

// the flat surface
show('isAbsolute cases', () => ['/a', 'a', './a', '', '/'].map((p) => path.isAbsolute(p)));
show('sep and delimiter', () => [path.sep, path.delimiter]);
show('posix is reachable', () => [typeof path.posix.join, path.posix.sep]);
show('win32 join', () => path.win32.join('a', 'b'));
show('win32 isAbsolute', () => [path.win32.isAbsolute('C:\\x'), path.win32.isAbsolute('/x'), path.win32.isAbsolute('x')]);
show('toNamespacedPath is identity here', () => path.toNamespacedPath('/a/b'));
show('matchesGlob exists', () => typeof path.matchesGlob);

console.log(out.join('\n'));
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
    print("PATH MATCH — all \(theirs.count) results identical to node's, across join, resolve, "
          + "normalize, relative, dirname, basename, extname, parse and format")
} else {
    print(differences.prefix(12).joined(separator: "\n"))
    print("MISMATCH: \(differences.count) of \(theirs.count)")
    exit(1)
}
try? FileManager.default.removeItem(at: base)
