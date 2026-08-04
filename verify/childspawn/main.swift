import Foundation
setvbuf(stdout, nil, _IONBF, 0)

// What a forked child is GIVEN, and what happens when it cannot be. Both halves were wrong in
// ways that produced silence rather than an error, which is the expensive kind of wrong: a
// child that starts, does nothing and never exits looks exactly like a child that is waiting.

let realNode = "/Users/thyfriendlyfox/.local/bin/node"
let base = FileManager.default.temporaryDirectory.appendingPathComponent("childspawn-\(getpid())")
try? FileManager.default.createDirectory(at: base.appendingPathComponent("lib/deep"), withIntermediateDirectories: true)
func put(_ text: String, _ name: String) {
    try? text.write(to: base.appendingPathComponent(name), atomically: true, encoding: .utf8)
}
put("process.send({ env: { prod: process.env.PROD, port: process.env.PORT, missing: process.env.NOPE } });\n",
    "lib/deep/child.cjs")

let script = #"""
const { fork } = require('child_process');
const path = require('path');
const here = path.dirname(process.argv[1]);

function trial(label, file, options) {
  return new Promise((resolve) => {
    const child = fork(file, [], options);
    let message = null, stderr = '';
    child.on('message', (m) => { message = m; });
    child.stderr && child.stderr.on('data', (d) => { stderr += String(d); });
    child.on('error', (e) => { stderr += 'error:' + e.message; });
    let settled = false;
    const finish = (text) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      try { child.kill(); } catch (error) {}
      resolve(text);
    };
    child.on('exit', (code) => {
      finish(label + ' -> exit=' + code + ' message=' + JSON.stringify(message)
             + ' said=' + (stderr.includes('Cannot find module') ? 'cannot-find-module'
                         : (stderr.trim() ? 'something' : 'nothing')));
    });
    const timer = setTimeout(() => finish(label + ' -> NEVER FINISHED (silent child)'), 3000);
  });
}

(async () => {
  const child = here + '/lib/deep/child.cjs';
  // node coerces env values to strings; a caller passing a boolean or a number is ordinary
  // (vitest passes PROD: false), and dropping the whole environment over one is not.
  console.log(await trial('typed env values', child, { stdio: 'pipe', env: { PROD: false, PORT: 5173 } }));
  // A path that walks back THROUGH a file. tinypool builds its worker path exactly this way.
  console.log(await trial('path through a file', here + '/lib/deep/child.cjs/../child.cjs',
                          { stdio: 'pipe', env: { PROD: true, PORT: 1 } }));
  // And a module that is not there at all must SAY so.
  console.log(await trial('missing module', here + '/lib/deep/nope.cjs', { stdio: 'pipe' }));
  process.exit(0);
})();
"""#

put(script, "probe.cjs")
let real = Process()
real.executableURL = URL(fileURLWithPath: realNode)
real.arguments = ["probe.cjs"]
real.currentDirectoryURL = base
let out = Pipe(), err = Pipe()
real.standardOutput = out
real.standardError = err
try? real.run()
let realText = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
_ = err.fileHandleForReading.readDataToEndOfFile()
real.waitUntilExit()

let engine = NodeEngine(root: base, env: ["PATH": "/"])
let ours = await engine.run(source: script, path: "/probe.cjs", argv: ["node", "/probe.cjs"], cwd: "/", stdin: "")
if !ours.err.isEmpty { print("ours stderr: \(ours.err.prefix(400))") }
print("---- ours ----\n\(ours.out)---- real ----\n\(realText)")

if ours.out == realText, !realText.isEmpty, !ours.out.contains("NEVER FINISHED") {
    print("CHILD SPAWN MATCH — typed env values arrive as node's strings, a path through a file "
          + "resolves, and a missing module says so instead of starting a child that does nothing")
} else {
    print("MISMATCH: forked child setup")
    exit(1)
}
try? FileManager.default.removeItem(at: base)
