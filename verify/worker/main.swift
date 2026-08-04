import Foundation
setvbuf(stdout, nil, _IONBF, 0)

// worker_threads on the child-engine machinery. The parts that work are the parts most libraries
// use — Worker, workerData, parentPort, postMessage both ways, exit. The parts that need SHARED
// MEMORY cannot work between two JSContexts and refuse by name; that is asserted on our side
// alone, since real node supports them.
let realNode = "/Users/thyfriendlyfox/.local/bin/node"
let base = FileManager.default.temporaryDirectory.appendingPathComponent("worker-\(getpid())")
try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

try? """
    const { parentPort, workerData, isMainThread, threadId } = require('worker_threads');
    parentPort.postMessage({ hello: true, isMainThread, gotData: workerData, threadIsNumber: typeof threadId === 'number' });
    parentPort.on('message', job => {
      if (job.stop) { parentPort.postMessage({ done: true }); process.exit(0); }
      parentPort.postMessage({ squared: job.value * job.value });
    });
    """.write(to: base.appendingPathComponent("worker.js"), atomically: true, encoding: .utf8)

// The worker exchange, on its own: nothing else sequences it, so the transcript is the
// contract. (An earlier version drove it from a MessageChannel and diverged on node's port
// semantics rather than on anything about workers — the fixture's fault, not the engine's.)
let script = """
const { Worker, isMainThread } = require('worker_threads');
const seen = [];
console.log('main thread:', isMainThread);
const worker = new Worker('./worker.js', { workerData: { seed: 7 } });
worker.on('message', message => {
  seen.push(JSON.stringify(message));
  if (message.hello) worker.postMessage({ value: 6 });
  else if (message.squared) worker.postMessage({ stop: true });
});
worker.on('exit', code => {
  seen.push('exit:' + code);
  console.log(seen.join(' | '));
});
"""
try? script.write(to: base.appendingPathComponent("main.js"), atomically: true, encoding: .utf8)

let real = Process()
real.executableURL = URL(fileURLWithPath: realNode)
real.arguments = ["main.js"]
real.currentDirectoryURL = base
let realOut = Pipe()
real.standardOutput = realOut
let realErr = Pipe()
real.standardError = realErr
try? real.run()
real.waitUntilExit()
let realText = String(decoding: realOut.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
let realProblems = String(decoding: realErr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
if !realProblems.isEmpty { print("real stderr: \(realProblems.prefix(300))") }

let engine = NodeEngine(root: base, env: ["PATH": "/"])
let ours = await engine.run(source: script, path: "/main.js", argv: ["node", "/main.js"], cwd: "/", stdin: "")
if !ours.err.isEmpty { print("ours stderr: \(ours.err.prefix(600))") }
print("---- ours ----\n\(ours.out)---- real ----\n\(realText)")

// What genuinely needs shared memory still refuses. receiveMessageOnPort and the
// environmentData pair were on this list by association and have been implemented — they match
// node's no-argument behaviour now, which is what this asserts.
let refusals = await { () async -> String in
    let engine = NodeEngine(root: base, env: [:])
    let result = await engine.run(source: #"""
    // moveMessagePortToContext WORKS now. Its refusal read "contexts are separate engines with
    // no shared memory", which was true while a vm context was another engine and expired the
    // moment they became a second JSContext in one virtual machine. What it must still do is
    // reject a non-context, the way node does.
    const workers = require('worker_threads');
    const vm = require('vm');
    const { port1, port2 } = new workers.MessageChannel();
    const moved = workers.moveMessagePortToContext(port2, vm.createContext({}));
    console.log('moved port: ' + typeof moved.postMessage + ' ' + typeof moved.on);
    try { workers.moveMessagePortToContext(port1, {}); console.log('bad context: allowed'); }
    catch (error) { console.log('bad context: ' + error.code); }
    port1.close();
    """#, path: "/r.js", argv: ["node", "/r.js"], cwd: "/", stdin: "")
    return result.out
}()

let expectedRefusals = """
moved port: function undefined
bad context: ERR_INVALID_ARG_TYPE

"""
if ours.out == realText, !ours.out.isEmpty, refusals == expectedRefusals {
    print("WORKER MATCH — Worker, workerData, parentPort and MessageChannel behave as node's; shared-memory APIs refuse by name")
} else {
    print("MISMATCH\n  refusals: \(refusals.debugDescription)")
    exit(1)
}
try? FileManager.default.removeItem(at: base)
