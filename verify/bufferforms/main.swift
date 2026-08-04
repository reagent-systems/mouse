import Foundation
setvbuf(stdout, nil, _IONBF, 0)

// Buffer, where a wrong answer is SILENT. node's `slice` returns a VIEW over the same memory —
// a Uint8Array's own slice copies — so an engine that inherits the wrong one loses every
// mutation made through the slice, and nothing reports anything. The rest of the surface is
// here for the same reason: encodings, ranged copies and searches are what binary code does all
// day, and each of them has an off-by-one waiting in it.

let realNode = "/Users/thyfriendlyfox/.local/bin/node"
let base = FileManager.default.temporaryDirectory.appendingPathComponent("bufferforms-\(getpid())")
try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

let script = #"""
const out = [];
function show(label, run) {
  try { out.push(label + ' -> ' + JSON.stringify(run())); }
  catch (error) { out.push(label + ' -> THREW ' + String(error.message).slice(0, 50)); }
}

// --- the aliasing rules: node's slice is a VIEW, and a view shares its memory ---
show('slice is a view', () => {
  const buffer = Buffer.from('abcdef');
  const part = buffer.slice(1, 3);
  part[0] = 0x5a;
  return [buffer.toString(), part.toString()];
});
show('subarray is a view', () => {
  const buffer = Buffer.from('abcdef');
  const part = buffer.subarray(2, 4);
  part[1] = 0x5a;
  return [buffer.toString(), part.toString()];
});
show('slice keeps byteOffset', () => {
  // The RELATIONSHIP, not the number: node allocates small buffers out of a shared pool, so the
  // absolute byteOffset is its allocator's business and asserting it would assert pooling.
  const buffer = Buffer.from('abcdef');
  const part = buffer.slice(2, 5);
  return [part.byteOffset - buffer.byteOffset, part.length, part.buffer === buffer.buffer];
});
show('from(arrayBuffer) shares', () => {
  const source = new Uint8Array([1, 2, 3, 4]);
  const view = Buffer.from(source.buffer, 1, 2);
  view[0] = 9;
  return [Array.from(source), Array.from(view)];
});
show('from(buffer) copies', () => {
  const original = Buffer.from('hi');
  const copy = Buffer.from(original);
  copy[0] = 0x5a;
  return [original.toString(), copy.toString()];
});
show('from(array) copies', () => {
  const numbers = [1, 2, 3];
  const buffer = Buffer.from(numbers);
  buffer[0] = 9;
  return [numbers[0], buffer[0]];
});

// --- comparison and search ---
show('compare and equals', () => [
  Buffer.from('abc').compare(Buffer.from('abd')),
  Buffer.from('abc').equals(Buffer.from('abc')),
  Buffer.compare(Buffer.from('b'), Buffer.from('a')),
]);
show('compare with ranges', () => Buffer.from('abcdef').compare(Buffer.from('xbcdx'), 1, 4, 1, 4));
show('indexOf string and byte', () => {
  const buffer = Buffer.from('hello hello');
  return [buffer.indexOf('llo'), buffer.indexOf('llo', 4), buffer.indexOf(0x6f), buffer.lastIndexOf('llo')];
});
show('indexOf with encoding', () => Buffer.from('68690a', 'hex').indexOf('690a', 0, 'hex'));
show('includes', () => [Buffer.from('abc').includes('bc'), Buffer.from('abc').includes('bd')]);
show('indexOf missing', () => Buffer.from('abc').indexOf('zz'));

// --- copy and fill with ranges ---
show('copy with ranges', () => {
  const target = Buffer.alloc(6, 0x2e);
  const written = Buffer.from('abcdef').copy(target, 1, 2, 5);
  return [written, target.toString()];
});
show('fill with a range', () => Buffer.alloc(6, 0x2e).fill('xy', 1, 5).toString());
show('fill with a buffer', () => Buffer.alloc(5).fill(Buffer.from('ab')).toString());

// --- writes and encodings ---
show('write returns bytes written', () => {
  const buffer = Buffer.alloc(4);
  const written = buffer.write('héllo', 0, 4, 'utf8');
  return [written, buffer.toString('hex')];
});
show('byteLength per encoding', () => ['utf8', 'latin1', 'hex', 'base64', 'utf16le']
  .map((encoding) => Buffer.byteLength(encoding === 'hex' ? '6869' : 'héllo', encoding)));
show('base64 round trip', () => Buffer.from('héllo').toString('base64'));
show('base64url', () => [Buffer.from([251, 255]).toString('base64'), Buffer.from([251, 255]).toString('base64url')]);
show('base64 with whitespace', () => Buffer.from('aGVs bG8=', 'base64').toString());
show('hex of an odd string', () => Buffer.from('abc', 'hex').length);
show('latin1 high bytes', () => Buffer.from([0xff, 0xfe]).toString('latin1'));
show('utf16le round trip', () => Buffer.from('hé', 'utf16le').toString('utf16le'));
show('ascii masks the high bit', () => Buffer.from([0xe9]).toString('ascii'));
show('invalid utf8 becomes replacement', () => Buffer.from([0xff, 0x61]).toString('utf8'));
show('toString with a range', () => Buffer.from('abcdef').toString('utf8', 2, 4));

// --- shape ---
show('toJSON', () => Buffer.from('hi').toJSON());
show('isBuffer and isEncoding', () => [Buffer.isBuffer(Buffer.alloc(1)), Buffer.isBuffer(new Uint8Array(1)),
                                       Buffer.isEncoding('utf8'), Buffer.isEncoding('nope')]);
show('concat with totalLength', () => Buffer.concat([Buffer.from('ab'), Buffer.from('cd')], 6).toString('hex'));
show('a Buffer is a Uint8Array', () => [Buffer.alloc(1) instanceof Uint8Array, Object.prototype.toString.call(Buffer.alloc(1))]);
show('swap16', () => Buffer.from([1, 2, 3, 4]).swap16().toString('hex'));

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
    print("BUFFER MATCH — all \(theirs.count) results identical to node's, aliasing and "
          + "encodings included")
} else {
    print(differences.prefix(12).joined(separator: "\n"))
    print("MISMATCH: \(differences.count) of \(theirs.count)")
    exit(1)
}
try? FileManager.default.removeItem(at: base)
