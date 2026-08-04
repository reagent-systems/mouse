import Foundation
setvbuf(stdout, nil, _IONBF, 0)

// `fs/promises` is what modern code imports — `const { readFile } = require('fs/promises')` is
// the first line of half of npm — and it is a PARALLEL surface to the callback API rather than
// a wrapper around it, so nothing about the sync gates says anything about this one. Including
// FileHandle, which is an object with its own methods and its own lifetime.

let realNode = "/Users/thyfriendlyfox/.local/bin/node"
let base = FileManager.default.temporaryDirectory.appendingPathComponent("fspromises-\(getpid())")
let realDir = base.appendingPathComponent("real"), ourDir = base.appendingPathComponent("ours")
for directory in [realDir, ourDir] {
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
}

let script = #"""
const fsp = require('fs/promises');
const fs = require('fs');
const path = require('path');

const out = [];
async function show(label, run) {
  try { out.push(label + ' -> ' + JSON.stringify(await run())); }
  catch (error) { out.push(label + ' -> THREW ' + (error.code || String(error.message).slice(0, 40))); }
}

(async () => {
  // --- the flat functions ---
  await show('writeFile then readFile', async () => {
    await fsp.writeFile('a.txt', 'first');
    return await fsp.readFile('a.txt', 'utf8');
  });
  await show('readFile without encoding', async () => {
    const data = await fsp.readFile('a.txt');
    return [Buffer.isBuffer(data), data.length];
  });
  await show('readFile options object', async () => await fsp.readFile('a.txt', { encoding: 'utf8' }));
  await show('appendFile', async () => {
    await fsp.appendFile('a.txt', '+more');
    return await fsp.readFile('a.txt', 'utf8');
  });
  await show('writeFile with a flag', async () => {
    await fsp.writeFile('a.txt', '+again', { flag: 'a' });
    return await fsp.readFile('a.txt', 'utf8');
  });
  await show('readFile missing', async () => await fsp.readFile('nope.txt', 'utf8'));
  await show('access on a file', async () => { await fsp.access('a.txt'); return 'ok'; });
  await show('access missing', async () => { await fsp.access('nope.txt'); return 'ok'; });
  await show('stat shape', async () => {
    const stat = await fsp.stat('a.txt');
    return [stat.isFile(), stat.isDirectory(), typeof stat.size, typeof stat.mtimeMs];
  });
  await show('lstat on a file', async () => (await fsp.lstat('a.txt')).isFile());
  await show('stat missing', async () => await fsp.stat('nope.txt'));

  // --- directories ---
  await show('mkdir recursive returns', async () => await fsp.mkdir('deep/deeper', { recursive: true }));
  await show('mkdir again recursive', async () => await fsp.mkdir('deep/deeper', { recursive: true }));
  await show('mkdir existing not recursive', async () => await fsp.mkdir('deep'));
  await show('readdir sorted', async () => (await fsp.readdir('.')).sort());
  await show('readdir withFileTypes', async () => {
    const entries = await fsp.readdir('.', { withFileTypes: true });
    const found = entries.find((entry) => entry.name === 'a.txt');
    return [found.isFile(), found.isDirectory(), typeof found.name];
  });
  await show('readdir recursive', async () => {
    await fsp.writeFile('deep/inner.txt', 'x');
    return (await fsp.readdir('.', { recursive: true })).sort();
  });
  await show('rm recursive', async () => {
    await fsp.mkdir('trash/inner', { recursive: true });
    await fsp.writeFile('trash/inner/f.txt', 'x');
    await fsp.rm('trash', { recursive: true });
    return fs.existsSync('trash');
  });
  await show('rm force on missing', async () => { await fsp.rm('gone', { force: true }); return 'ok'; });
  await show('rm missing without force', async () => await fsp.rm('gone'));
  await show('rmdir on a file', async () => await fsp.rmdir('a.txt'));

  // --- moving and copying ---
  await show('copyFile then rename', async () => {
    await fsp.copyFile('a.txt', 'b.txt');
    await fsp.rename('b.txt', 'c.txt');
    return [fs.existsSync('b.txt'), await fsp.readFile('c.txt', 'utf8')];
  });
  await show('mkdtemp', async () => {
    const made = await fsp.mkdtemp('tmp-');
    return [made.startsWith('tmp-'), made.length > 4, fs.existsSync(made)];
  });
  await show('realpath', async () => (await fsp.realpath('a.txt')).endsWith('a.txt'));

  // --- FileHandle ---
  await show('open + read + close', async () => {
    const handle = await fsp.open('a.txt', 'r');
    const buffer = Buffer.alloc(5);
    const result = await handle.read(buffer, 0, 5, 0);
    await handle.close();
    return [result.bytesRead, buffer.toString()];
  });
  await show('handle.readFile', async () => {
    const handle = await fsp.open('a.txt', 'r');
    const text = await handle.readFile('utf8');
    await handle.close();
    return text;
  });
  await show('handle.write then stat', async () => {
    const handle = await fsp.open('d.txt', 'w');
    const written = await handle.write('written');
    const stat = await handle.stat();
    await handle.close();
    return [written.bytesWritten, stat.size];
  });
  await show('handle.truncate', async () => {
    const handle = await fsp.open('d.txt', 'r+');
    await handle.truncate(3);
    await handle.close();
    return await fsp.readFile('d.txt', 'utf8');
  });
  await show('handle has a fd', async () => {
    const handle = await fsp.open('a.txt', 'r');
    const kind = typeof handle.fd;
    await handle.close();
    return kind;
  });

  // --- the module's shape ---
  await show('exported names', async () => ['readFile', 'writeFile', 'appendFile', 'access', 'stat',
    'lstat', 'readdir', 'mkdir', 'rm', 'rmdir', 'rename', 'copyFile', 'unlink', 'open', 'opendir',
    'realpath', 'mkdtemp', 'truncate', 'chmod', 'utimes', 'symlink', 'readlink', 'watch', 'cp']
    .map((name) => typeof fsp[name]).join(','));

  console.log(out.join('\n'));
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
if !realProblems.isEmpty { print("real stderr: \(realProblems.prefix(300))") }

let engine = NodeEngine(root: ourDir, env: ["PATH": "/"])
let ours = await engine.run(source: script, path: "/probe.cjs", argv: ["node", "/probe.cjs"], cwd: "/", stdin: "")
if !ours.err.isEmpty { print("ours stderr: \(ours.err.prefix(400))") }

// mkdtemp and readdir name a random directory; compare the SHAPE of those lines.
func normalise(_ line: String) -> String {
    guard let range = line.range(of: #"tmp-[A-Za-z0-9]+"#, options: .regularExpression) else { return line }
    return line.replacingCharacters(in: range, with: "tmp-XXXX")
}
let theirs = realText.components(separatedBy: "\n").filter { !$0.isEmpty }.map(normalise)
let mine = ours.out.components(separatedBy: "\n").filter { !$0.isEmpty }.map(normalise)
var differences: [String] = []
for (index, line) in theirs.enumerated() {
    let ourLine = index < mine.count ? mine[index] : "(missing)"
    if ourLine != line { differences.append("  ours: \(ourLine)\n  node: \(line)") }
}
for extra in mine.dropFirst(theirs.count) { differences.append("  ours said extra: \(extra)") }

if differences.isEmpty, !theirs.isEmpty {
    print("FS PROMISES MATCH — all \(theirs.count) results identical to node's, FileHandle included")
} else {
    print(differences.prefix(14).joined(separator: "\n"))
    print("MISMATCH: \(differences.count) of \(theirs.count)")
    exit(1)
}
try? FileManager.default.removeItem(at: base)
