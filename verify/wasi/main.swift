import Foundation
setvbuf(stdout, nil, _IONBF, 0)

// `node:wasi` — WASI preview1, checked against node's own. The test module is assembled BY HAND
// here, in the house tradition (tar, gzip, ICMP, DER): a real WebAssembly binary that imports
// fd_write, owns a page of memory, and writes a string through the syscall on `_start`. Both
// engines run the same bytes, and then the same syscalls are called directly through the import
// object so the parts a small module cannot reach are compared too.

let realNode = "/Users/thyfriendlyfox/.local/bin/node"
let base = FileManager.default.temporaryDirectory.appendingPathComponent("wasi-\(getpid())")
try? FileManager.default.createDirectory(at: base.appendingPathComponent("sandbox"), withIntermediateDirectories: true)
try? "a file the module can open\n".write(to: base.appendingPathComponent("sandbox/note.txt"),
                                          atomically: true, encoding: .utf8)

// ---- the module, byte by byte ----
func leb(_ value: Int) -> [UInt8] {
    var remaining = value, out: [UInt8] = []
    repeat {
        var byte = UInt8(remaining & 0x7f)
        remaining >>= 7
        if remaining != 0 { byte |= 0x80 }
        out.append(byte)
    } while remaining != 0
    return out
}
func section(_ id: UInt8, _ body: [UInt8]) -> [UInt8] { [id] + leb(body.count) + body }
func vector(_ items: [[UInt8]]) -> [UInt8] { leb(items.count) + items.flatMap { $0 } }
func name(_ text: String) -> [UInt8] { leb(text.utf8.count) + Array(text.utf8) }

let message = "hello from wasi\n"
// (i32 i32 i32 i32) -> i32   for fd_write, and () -> () for _start
// Split into named pieces: the type checker gives up on one long array expression.
var writeType: [UInt8] = [0x60]
writeType += leb(4)
writeType += [0x7f, 0x7f, 0x7f, 0x7f]
writeType += leb(1)
writeType += [0x7f]
var startType: [UInt8] = [0x60]
startType += leb(0)
startType += leb(0)
let types = section(1, vector([writeType, startType]))
var importEntry: [UInt8] = name("wasi_snapshot_preview1")
importEntry += name("fd_write")
importEntry += [0x00]
importEntry += leb(0)
let imports = section(2, vector([importEntry]))
let functions = section(3, vector([leb(1)]))                     // one local function, type 1
var memoryEntry: [UInt8] = [0x00]
memoryEntry += leb(1)                                            // one page, no maximum
let memories = section(5, vector([memoryEntry]))
var memoryExport: [UInt8] = name("memory")
memoryExport += [0x02]
memoryExport += leb(0)
var startExport: [UInt8] = name("_start")
startExport += [0x00]
startExport += leb(1)
let exports = section(7, vector([memoryExport, startExport]))
// _start: fd_write(1, iovs=0, iovs_len=1, nwritten=4)
var body: [UInt8] = leb(0)              // no locals
for constant in [1, 0, 1, 4] {          // fd, iovs, iovs_len, nwritten
    body += [0x41]
    body += leb(constant)
}
body += [0x10]                          // call
body += leb(0)                          // import 0: fd_write
body += [0x1a, 0x0b]                    // drop, end
var codeEntry: [UInt8] = leb(body.count)
codeEntry += body
let code = section(10, vector([codeEntry]))
// data: the iovec at 0 {ptr: 8, len}, and the text at 8
var iovec: [UInt8] = [8, 0, 0, 0]
iovec += [UInt8(message.utf8.count), 0, 0, 0]
func dataSegment(at offset: Int, _ payload: [UInt8]) -> [UInt8] {
    var out: [UInt8] = [0x00, 0x41]
    out += leb(offset)
    out += [0x0b]
    out += leb(payload.count)
    out += payload
    return out
}
let data = section(11, vector([dataSegment(at: 0, iovec), dataSegment(at: 8, Array(message.utf8))]))
var module: [UInt8] = [0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00]
for piece in [types, imports, functions, memories, exports, code, data] { module += piece }
try? Data(module).write(to: base.appendingPathComponent("hello.wasm"))
print("hand-assembled module: \(module.count) bytes")

let script = #"""
const { WASI } = require('node:wasi');
const fs = require('fs');

const wasi = new WASI({
  version: 'preview1',
  args: ['hello.wasm', 'first', 'second'],
  env: { GREETING: 'hi', COUNT: '2' },
  preopens: { '/work': PREOPEN },
  returnOnExit: true,
});

// 1. The module itself: instantiate with the import object and let _start run.
const bytes = fs.readFileSync(WASM);
const compiled = new WebAssembly.Module(bytes);
const instance = new WebAssembly.Instance(compiled, wasi.getImportObject());
const status = wasi.start(instance);
console.log('start returned', status);

// 2. The syscalls a sixteen-byte program cannot reach, called straight through the import
// object — the same surface a real module drives, one call at a time.
const memory = instance.exports.memory;
const view = new DataView(memory.buffer);
const bytesOf = new Uint8Array(memory.buffer);
const imports = wasi.wasiImport;
const P = 1024;

imports.args_sizes_get(P, P + 4);
console.log('args:', view.getUint32(P, true), 'bytes', view.getUint32(P + 4, true));
imports.args_get(P + 16, P + 128);
const firstArg = view.getUint32(P + 16, true);
console.log('first arg at', firstArg - P - 128, 'is',
            JSON.stringify(Buffer.from(bytesOf.subarray(firstArg, firstArg + 10)).toString().split('\0')[0]));

imports.environ_sizes_get(P, P + 4);
console.log('environ:', view.getUint32(P, true), 'bytes', view.getUint32(P + 4, true));

console.log('clock_res_get:', imports.clock_res_get(0, P));
const before = Date.now();
imports.clock_time_get(0, 0n, P);
const wall = Number(view.getBigUint64(P, true) / 1000000n);
console.log('realtime clock is sane:', Math.abs(wall - before) < 5000);

bytesOf.fill(0, P, P + 16);
console.log('random_get:', imports.random_get(P, 16),
            'filled:', bytesOf.subarray(P, P + 16).some((b) => b !== 0));

console.log('fd_prestat_get(3):', imports.fd_prestat_get(3, P), 'name length',
            view.getUint32(P + 4, true));
imports.fd_prestat_dir_name(3, P + 16, view.getUint32(P + 4, true));
console.log('preopen name:', JSON.stringify(Buffer.from(
  bytesOf.subarray(P + 16, P + 16 + view.getUint32(P + 4, true))).toString()));

console.log('fd_fdstat_get(3) type:', imports.fd_fdstat_get(3, P) === 0 ? view.getUint8(P) : 'error');
console.log('fd_prestat_get(9) on nothing:', imports.fd_prestat_get(9, P));
console.log('fd_close(9) on nothing:', imports.fd_close(9));

// A real file, opened through the preopened directory and read back.
const NAME = 'note.txt';
bytesOf.set(Buffer.from(NAME), P + 512);
const opened = imports.path_open(3, 0, P + 512, NAME.length, 0, 0n, 0n, 0, P);
const fd = view.getUint32(P, true);
console.log('path_open:', opened, 'gave a descriptor above stdio:', fd > 2);
view.setUint32(P + 600, P + 700, true);
view.setUint32(P + 604, 64, true);
const readResult = imports.fd_read(fd, P + 600, 1, P + 608);
const readCount = view.getUint32(P + 608, true);
console.log('fd_read:', readResult, JSON.stringify(
  Buffer.from(bytesOf.subarray(P + 700, P + 700 + readCount)).toString()));
console.log('fd_seek to 2:', imports.fd_seek(fd, 2n, 0, P + 616), 'tell says',
            Number(view.getBigUint64(P + 616, true)));
console.log('fd_filestat_get size:', imports.fd_filestat_get(fd, P + 640) === 0
            ? Number(view.getBigUint64(P + 640 + 32, true)) : 'error');
console.log('fd_close:', imports.fd_close(fd));

bytesOf.set(Buffer.from('missing.txt'), P + 512);
console.log('path_open on a missing file:', imports.path_open(3, 0, P + 512, 11, 0, 0n, 0n, 0, P));
bytesOf.set(Buffer.from(NAME), P + 512);
console.log('path_filestat_get:', imports.path_filestat_get(3, 0, P + 512, NAME.length, P + 640) === 0
            ? Number(view.getBigUint64(P + 640 + 32, true)) : 'error');
console.log('sched_yield:', imports.sched_yield());
console.log('sock_send is refused:', imports.sock_send(0, 0, 0, 0, 0));
"""#

func write(_ text: String, to directory: URL) {
    try? text.write(to: directory.appendingPathComponent("probe.cjs"), atomically: true, encoding: .utf8)
}
let realScript = script
    .replacingOccurrences(of: "PREOPEN", with: "'\(base.appendingPathComponent("sandbox").path)'")
    .replacingOccurrences(of: "WASM", with: "'\(base.appendingPathComponent("hello.wasm").path)'")
let ourScript = script
    .replacingOccurrences(of: "PREOPEN", with: "'/sandbox'")
    .replacingOccurrences(of: "WASM", with: "'/hello.wasm'")
write(realScript, to: base)

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
if !realProblems.isEmpty { print("real stderr: \(realProblems.prefix(500))") }

let engine = NodeEngine(root: base, env: ["PATH": "/"])
let ours = await engine.run(source: ourScript, path: "/probe.cjs", argv: ["node", "/probe.cjs"], cwd: "/", stdin: "")
if !ours.err.isEmpty { print("ours stderr: \(ours.err.prefix(900))") }

print("---- ours ----\n\(ours.out)---- real ----\n\(realText)")
if ours.out == realText, realText.contains("hello from wasi"), realText.contains("start returned 0") {
    let lines = realText.components(separatedBy: "\n").filter { !$0.isEmpty }.count
    print("WASI MATCH — a hand-assembled wasm module wrote through fd_write and \(lines - 1) "
          + "syscall results are identical to node's own WASI, files and errors included")
} else {
    print("MISMATCH: WASI preview1")
    exit(1)
}
try? FileManager.default.removeItem(at: base)
