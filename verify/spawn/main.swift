import Foundation
setvbuf(stdout, nil, _IONBF, 0)

// A live child process: `spawn('node', …)` runs a SECOND engine with real pipes, so a parent can
// talk to a long-running peer instead of collecting a finished command's output. That is the
// capability esbuild-wasm needs, and the one child_process never had here.
let realNode = "/Users/thyfriendlyfox/.local/bin/node"
let base = FileManager.default.temporaryDirectory.appendingPathComponent("spawn-\(getpid())")
try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

// The child: reads lines, answers each one, and exits when its input ends. The exchange has to
// be INTERLEAVED — the parent's second request depends on the child's first answer, so a
// collect-then-report implementation cannot pass this.
try? """
    let count = 0;
    process.stdin.setEncoding('utf8');
    process.stdin.on('data', chunk => {
      for (const line of String(chunk).split('\\n')) {
        if (!line) continue;
        count += 1;
        if (line === 'quit') { process.stdout.write('bye after ' + count + '\\n'); process.exit(7); }
        process.stdout.write('reply ' + count + ' to ' + line + '\\n');
      }
    });
    process.stdin.on('end', () => { process.stdout.write('input ended\\n'); });
    process.stderr.write('child up\\n');
    """.write(to: base.appendingPathComponent("child.js"), atomically: true, encoding: .utf8)

let parent = """
const { spawn } = require('child_process');
const child = spawn('node', ['child.js']);
const seen = [];
let asked = 0;
child.stdout.setEncoding('utf8');
child.stdout.on('data', chunk => {
  for (const line of String(chunk).split('\\n')) {
    if (!line) continue;
    seen.push(line);
    // Each request waits for the previous answer: a collected-output child could never do this.
    if (line.startsWith('reply')) {
      asked += 1;
      if (asked < 3) child.stdin.write('ask' + asked + '\\n');
      else child.stdin.write('quit\\n');
    }
  }
});
child.stderr.setEncoding('utf8');
child.stderr.on('data', chunk => seen.push('stderr:' + String(chunk).trim()));
child.on('exit', code => seen.push('exit:' + code));
// The watchdog exists so a hang is visible; clearing it on close is what makes the transcript
// end where the exchange does, in both engines.
const watchdog = setTimeout(() => { console.log('TIMEOUT ' + seen.join(' | ')); process.exit(1); }, 8000);
child.on('close', code => {
  clearTimeout(watchdog);
  seen.push('close:' + code);
  console.log(seen.join(' | '));
  console.log('pid is a number:', typeof child.pid === 'number', 'exitCode:', child.exitCode);
});
child.stdin.write('ask0\\n');
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
if !ours.err.isEmpty { print("ours stderr: \(ours.err.prefix(600))") }

print("---- ours ----\n\(ours.out)---- real ----\n\(realText)")
if ours.out == realText, !ours.out.isEmpty, !ours.out.contains("TIMEOUT") {
    print("SPAWN MATCH — a live node child, interleaved over real pipes, exactly as node does")
} else {
    print("MISMATCH")
    exit(1)
}
try? FileManager.default.removeItem(at: base)
