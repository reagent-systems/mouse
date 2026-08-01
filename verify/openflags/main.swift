import Foundation
setvbuf(stdout, nil, _IONBF, 0)

// How a SYSCALL layer opens a file: with numeric flags, not "w". Go's wasm runtime does it, every
// WASI shim does it, and `String(flags)` turned O_WRONLY|O_CREAT|O_TRUNC into the string "1537",
// which contains neither 'w' nor 'a' — so the open read as read-only and the writes that followed
// were appended rather than placed, putting the content in the file twice.

let realNode = "/Users/thyfriendlyfox/.local/bin/node"
// Each engine gets its OWN tree: an exclusive-create test is a trap otherwise, since whoever
// runs first leaves the file behind and the second run sees EEXIST for the wrong reason.
let base = FileManager.default.temporaryDirectory.appendingPathComponent("openflags-\(getpid())")
let realDir = base.appendingPathComponent("real"), ourDir = base.appendingPathComponent("ours")
for directory in [realDir, ourDir] {
    try? FileManager.default.createDirectory(at: directory.appendingPathComponent("out"), withIntermediateDirectories: true)
}
let script = """
const fs = require('fs');
const C = fs.constants;
function attempt(label, run) {
  try { console.log(label, '->', run()); } catch (e) { console.log(label, '-> THREW', String(e.message).slice(0, 60)); }
}
attempt('string flag w    ', () => { const fd = fs.openSync('out/a.txt', 'w'); fs.writeSync(fd, 'one'); fs.closeSync(fd); return fs.readFileSync('out/a.txt', 'utf8'); });
attempt('numeric O_WRONLY ', () => { const fd = fs.openSync('out/b.txt', C.O_WRONLY | C.O_CREAT | C.O_TRUNC, 0o666); fs.writeSync(fd, 'two'); fs.closeSync(fd); return fs.readFileSync('out/b.txt', 'utf8'); });
attempt('numeric O_RDONLY ', () => { const fd = fs.openSync('out/b.txt', C.O_RDONLY); const buf = Buffer.alloc(3); fs.readSync(fd, buf, 0, 3, 0); fs.closeSync(fd); return buf.toString(); });
attempt('numeric O_RDWR   ', () => { const fd = fs.openSync('out/c.txt', C.O_RDWR | C.O_CREAT, 0o666); fs.writeSync(fd, 'three'); fs.closeSync(fd); return fs.readFileSync('out/c.txt', 'utf8'); });
attempt('numeric O_APPEND ', () => { const fd = fs.openSync('out/a.txt', C.O_WRONLY | C.O_APPEND, 0o666); fs.writeSync(fd, '+more'); fs.closeSync(fd); return fs.readFileSync('out/a.txt', 'utf8'); });
attempt('numeric O_EXCL twice', () => { const fd = fs.openSync('out/x.txt', C.O_WRONLY | C.O_CREAT | C.O_EXCL, 0o666); fs.closeSync(fd); try { fs.closeSync(fs.openSync('out/x.txt', C.O_WRONLY | C.O_CREAT | C.O_EXCL, 0o666)); return 'no error'; } catch (e) { return e.code; } });
attempt('read-only numeric   ', () => { try { fs.openSync('out/missing.txt', C.O_RDONLY); return 'no error'; } catch (e) { return e.code; } });
// The same option, spelled the other ways node allows it.
attempt('writeFileSync flag a', () => { fs.writeFileSync('out/d.txt', 'one'); fs.writeFileSync('out/d.txt', 'two', { flag: 'a' }); return fs.readFileSync('out/d.txt', 'utf8'); });
attempt('writeFileSync numeric flag', () => { fs.writeFileSync('out/e.txt', 'keep'); fs.writeFileSync('out/e.txt', '+add', { flag: C.O_WRONLY | C.O_APPEND }); return fs.readFileSync('out/e.txt', 'utf8'); });
attempt('appendFileSync      ', () => { fs.writeFileSync('out/f.txt', 'a'); fs.appendFileSync('out/f.txt', 'b'); return fs.readFileSync('out/f.txt', 'utf8'); });
attempt('two writes one fd   ', () => { const fd = fs.openSync('out/g.txt', 'w'); fs.writeSync(fd, 'first'); fs.writeSync(fd, 'second'); fs.closeSync(fd); return fs.readFileSync('out/g.txt', 'utf8'); });
attempt('write at a position ', () => { const fd = fs.openSync('out/h.txt', 'w'); fs.writeSync(fd, 'abcdef'); fs.writeSync(fd, 'XY', 0, 2, 2); fs.closeSync(fd); return fs.readFileSync('out/h.txt', 'utf8'); });
attempt('read after seek     ', () => { const fd = fs.openSync('out/h.txt', 'r'); const buf = Buffer.alloc(2); fs.readSync(fd, buf, 0, 2, 2); fs.closeSync(fd); return buf.toString(); });
attempt('accessSync numeric  ', () => { fs.accessSync('out/h.txt', C.R_OK | C.W_OK); return 'ok'; });
attempt('ftruncate to 3      ', () => { const fd = fs.openSync('out/h.txt', 'r+'); fs.ftruncateSync(fd, 3); fs.closeSync(fd); return fs.readFileSync('out/h.txt', 'utf8'); });
attempt('createWriteStream a ', () => { fs.writeFileSync('out/i.txt', 'x'); const stream = fs.createWriteStream('out/i.txt', { flags: 'a' }); stream.write('y'); stream.end(); return 'queued'; });
console.log('constants:', C.O_WRONLY, C.O_CREAT, C.O_TRUNC, C.O_APPEND, C.O_RDWR);
"""
for directory in [realDir, ourDir] {
    try? script.write(to: directory.appendingPathComponent("p.cjs"), atomically: true, encoding: .utf8)
}
let process = Process()
process.executableURL = URL(fileURLWithPath: realNode)
process.arguments = ["p.cjs"]
process.currentDirectoryURL = realDir
let out = Pipe(); process.standardOutput = out; process.standardError = Pipe()
try? process.run()
let real = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
process.waitUntilExit()
let engine = NodeEngine(root: ourDir, env: ["PATH": "/"])
let ours = await engine.run(source: script, path: "/p.cjs", argv: ["node", "/p.cjs"], cwd: "/", stdin: "")
print("---- ours ----\n\(ours.out)---- real ----\n\(real)")
if ours.out == real, !real.isEmpty {
    print("OPEN FLAGS MATCH — a file opened with NUMERIC flags reads and writes as node's does, "
          + "and a descriptor writes at its own position instead of appending")
} else {
    print("MISMATCH: numeric open flags or positional writes")
    exit(1)
}
try? FileManager.default.removeItem(at: base)
