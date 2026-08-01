import Foundation
setvbuf(stdout, nil, _IONBF, 0)

// fork()'s message channel. What distinguishes fork from spawn is exactly this channel, and
// `if (process.send)` is how every worker library asks whether it was forked — so a stub would
// be worse than nothing. Compared against real node on a two-way exchange.
let realNode = "/Users/thyfriendlyfox/.local/bin/node"
let base = FileManager.default.temporaryDirectory.appendingPathComponent("fork-\(getpid())")
try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

try? """
    // A worker: answers each job, reports when the channel closes, and says whether it can tell
    // it was forked at all.
    process.send({ ready: true, forked: typeof process.send === 'function', connected: process.connected });
    process.on('message', job => {
      if (job.done) { process.send({ bye: true }); process.exit(0); }
      process.send({ result: job.value * 2, of: job.value });
    });
    """.write(to: base.appendingPathComponent("worker.js"), atomically: true, encoding: .utf8)

let parent = """
const { fork } = require('child_process');
const child = fork('worker.js');
const seen = [];
let sent = 0;
child.on('message', message => {
  seen.push(JSON.stringify(message));
  if (message.ready) child.send({ value: 21 });
  else if (message.result !== undefined) {
    sent += 1;
    if (sent < 2) child.send({ value: message.result });
    else child.send({ done: true });
  }
});
child.on('exit', code => {
  seen.push('exit:' + code);
  // Only after the fork conversation is over: a plain spawn must NOT have the channel, and two
  // children running at once would order their output by luck rather than by contract.
  const { spawn } = require('child_process');
  const plain = spawn('node', ['-e', 'console.log("plain: send is " + typeof process.send)']);
  plain.stdout.on('data', chunk => seen.push(String(chunk).trim()));
  plain.on('close', () => {
    clearTimeout(watchdog);
    console.log(seen.join(' | '));
    console.log('channel present:', typeof child.send === 'function', 'connected:', child.connected);
  });
});
// The watchdog makes a hang visible; clearing it on completion is what ends the transcript
// where the exchange does, in both engines.
const watchdog = setTimeout(() => { console.log('TIMEOUT ' + seen.join(' | ')); process.exit(1); }, 8000);
"""
try? parent.write(to: base.appendingPathComponent("parent.js"), atomically: true, encoding: .utf8)

let real = Process()
real.executableURL = URL(fileURLWithPath: realNode)
real.arguments = ["parent.js"]
real.currentDirectoryURL = base
let realOut = Pipe()
real.standardOutput = realOut
real.standardError = Pipe()
try? real.run()
real.waitUntilExit()
let realText = String(decoding: realOut.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)

let engine = NodeEngine(root: base, env: ["PATH": "/"])
let ours = await engine.run(source: parent, path: "/parent.js", argv: ["node", "/parent.js"], cwd: "/", stdin: "")
if !ours.err.isEmpty { print("ours stderr: \(ours.err.prefix(500))") }
print("---- ours ----\n\(ours.out)---- real ----\n\(realText)")
if ours.out == realText, !ours.out.isEmpty, !ours.out.contains("TIMEOUT") {
    print("FORK MATCH — a real message channel, and spawn correctly has none")
} else {
    print("MISMATCH")
    exit(1)
}
try? FileManager.default.removeItem(at: base)
