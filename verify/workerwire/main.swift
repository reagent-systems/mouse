import Foundation
setvbuf(stdout, nil, _IONBF, 0)

// Four behaviours a worker pool leans on, each found by chasing vitest's and each checkable
// against real node on its own: a MessagePort with no own enumerable properties, source
// compiled at runtime that can still `import()`, SharedArrayBuffer inside one engine, and
// child IPC that serialises the way node does in each of its two modes.

let realNode = "/Users/thyfriendlyfox/.local/bin/node"
let base = FileManager.default.temporaryDirectory.appendingPathComponent("workerwire-\(getpid())")
try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

let script = #"""
const { MessageChannel, MessagePort } = require('worker_threads');
const { fork } = require('child_process');
const path = require('path');

// 1. A port carries NO own enumerable properties. Real code spreads one: tinypool relays every
// worker message as `{ ...message, source: 'port' }`, and an internal pointing back at the port
// makes that spread cyclic — unserialisable, and nothing says why.
const channel = new MessageChannel();
console.log('port own keys:', JSON.stringify(Object.keys(channel.port1)));
console.log('port spread:', JSON.stringify({ ...channel.port1 }));
console.log('port is a MessagePort:', channel.port1 instanceof MessagePort);

// 2. Source compiled at RUNTIME can still import. `new Function("s", "return import(s)")` is the
// standard way to keep a dynamic import out of a CommonJS transpile.
const runtimeImport = new Function('specifier', 'return import(specifier)');
runtimeImport('node:path').then((m) => {
  console.log('runtime import:', typeof m.join === 'function' || typeof m.default.join === 'function');
}).catch((error) => console.log('runtime import FAILED:', String(error.message).slice(0, 60)));

// 3. SharedArrayBuffer exists and Atomics work on it, within one engine.
const shared = new Int32Array(new SharedArrayBuffer(8));
Atomics.store(shared, 0, 41);
Atomics.add(shared, 0, 1);
console.log('atomics:', Atomics.load(shared, 0), shared.buffer instanceof SharedArrayBuffer);

// 4. Child IPC serialisation: 'json' is node's default and DROPS a function; 'advanced' is the
// structured clone algorithm and keeps a Map. Getting this backwards makes the engine stricter
// than node, which is how a message carrying a callback becomes an unexplained throw.
const childSource = "process.on('message', (m) => { process.send({ echo: m, hasFn: typeof m.fn, "
  + "mapSize: (m.map instanceof Map) ? m.map.size : 'not-a-map' }); process.exit(0); });";
require('fs').writeFileSync(path.join(process.cwd(), 'child.cjs'), childSource);

function roundTrip(mode, message) {
  return new Promise((resolve) => {
    const child = fork('./child.cjs', [], mode ? { serialization: mode } : {});
    child.on('message', (m) => { resolve(String(mode) + ': fn=' + m.hasFn + ' map=' + m.mapSize + ' keep=' + m.echo.keep); });
    child.on('error', (e) => resolve(String(mode) + ': error ' + e.message.slice(0, 40)));
    child.send(message);
  });
}
(async () => {
  // json (node's default) DROPS a function and flattens a Map — the semantics of JSON, and the
  // reason a message carrying a callback must not throw here.
  console.log(await roundTrip(undefined, { fn: function () {}, map: new Map([['a', 1]]), keep: 'yes' }));
  // advanced is the structured clone algorithm: the Map survives as a Map.
  console.log(await roundTrip('advanced', { map: new Map([['a', 1]]), keep: 'yes' }));
})();
"""#

try? script.write(to: base.appendingPathComponent("probe.cjs"), atomically: true, encoding: .utf8)
let real = Process()
real.executableURL = URL(fileURLWithPath: realNode)
real.arguments = ["probe.cjs"]
real.currentDirectoryURL = base
let out = Pipe(), err = Pipe()
real.standardOutput = out
real.standardError = err
try? real.run()
let realText = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
let realProblems = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
real.waitUntilExit()
if !realProblems.isEmpty { print("real stderr: \(realProblems.prefix(400))") }

let engine = NodeEngine(root: base, env: ["PATH": "/"])
let ours = await engine.run(source: script, path: "/probe.cjs", argv: ["node", "/probe.cjs"], cwd: "/", stdin: "")
if !ours.err.isEmpty { print("ours stderr: \(ours.err.prefix(600))") }

// Both engines print the same lines, but a child can answer in either order.
func sorted(_ text: String) -> [String] {
    text.components(separatedBy: "\n").filter { !$0.isEmpty }.sorted()
}
print("---- ours ----\n\(ours.out)---- real ----\n\(realText)")

// And the half real node cannot demonstrate: sharing a SharedArrayBuffer with a worker is
// impossible here — two engines cannot address one buffer — so it must SAY so rather than
// arrive as an unrelated copy nobody would think to check.
let refusal = await NodeEngine(root: base, env: ["PATH": "/"]).run(source: """
    const { Worker } = require('worker_threads');
    try {
      new Worker('/dev/null', { workerData: new SharedArrayBuffer(8), eval: false });
      console.log('no refusal');
    } catch (error) { console.log('refused:', error.name, String(error.message).slice(0, 60)); }
    """, path: "/share.cjs", argv: ["node", "/share.cjs"], cwd: "/", stdin: "")
print("sharing across engines: \(refusal.out.trimmingCharacters(in: .whitespacesAndNewlines))")

if sorted(ours.out) == sorted(realText), !realText.isEmpty,
   refusal.out.contains("refused: DataCloneError") {
    print("WORKER WIRE MATCH — ports, runtime-compiled imports, atomics and both IPC "
          + "serialisation modes behave as real node's, and sharing memory across engines refuses")
} else {
    print("MISMATCH: worker plumbing")
    exit(1)
}
try? FileManager.default.removeItem(at: base)
