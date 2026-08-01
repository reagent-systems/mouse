import Foundation
setvbuf(stdout, nil, _IONBF, 0)

// A DIAGNOSTIC: how far vitest gets. Everything up to the worker handshake now works — the pool
// starts, the fork happens, the pool message goes out with a port and a shared buffer, and by
// hand the same child answers `ready`. In the real run it does not, and produces no output on
// either stream while doing so. Four engine defects were fixed getting this far (see the
// workerwire gate); this records where the chase stopped rather than letting the lead rot.

let base = FileManager.default.temporaryDirectory.appendingPathComponent("vitest-\(getpid())")
try? FileManager.default.createDirectory(at: base.appendingPathComponent("app/src"), withIntermediateDirectories: true)
let app = base.appendingPathComponent("app")
do { _ = try await PackageManager.install(requirements: ["vitest": "^2.1.0"], into: base) }
catch { print("install failed: \(error)"); exit(0) }

func put(_ text: String, _ name: String) {
    try? text.write(to: app.appendingPathComponent(name), atomically: true, encoding: .utf8)
}
put(#"{ "name": "suite", "private": true, "type": "module" }"#, "package.json")
put("export const add = (a: number, b: number): number => a + b;\n", "src/math.ts")
put("""
    import { describe, it, expect } from 'vitest';
    import { add } from './src/math.ts';
    describe('math', () => {
      it('adds', () => { expect(add(2, 3)).toBe(5); });
      it('fails on purpose', () => { expect(add(1, 1)).toBe(3); });
    });
    """, "math.test.ts")
put("""
    import cp from 'child_process';
    const realFork = cp.fork;
    cp.fork = function(file, args, options) {
      console.log('FORKENV', JSON.stringify(Object.keys((options || {}).env || {})));
      const child = realFork.call(this, file, args, options);
      child.on('message', (m) => console.log('FROM CHILD', JSON.stringify(m).slice(0, 100)));
      child.stderr && child.stderr.on('data', (d) => console.log('CHILD STDERR', String(d).slice(0, 300)));
      return child;
    };
    import { startVitest } from 'vitest/node';
    const vitest = await startVitest('test', [], { watch: false, reporters: ['basic'], pool: 'forks' });
    let passed = 0, failed = 0;
    for (const file of vitest.state.getFiles()) for (const task of file.tasks || []) {
      if (task.result && task.result.state === 'pass') passed++;
      if (task.result && task.result.state === 'fail') failed++;
    }
    console.log('RESULT passed=' + passed + ' failed=' + failed);
    await vitest.close();
    process.exit(0);
    """, "run.mjs")

let source = try! String(contentsOf: app.appendingPathComponent("run.mjs"), encoding: .utf8)
let engine = NodeEngine(root: base, env: ["PATH": "/", "HOME": "/", "CI": "true"])
let result = await engine.run(source: source, path: "/app/run.mjs", argv: ["node", "/app/run.mjs"],
                              cwd: "/app", stdin: "")
if let line = result.out.components(separatedBy: "\n").first(where: { $0.hasPrefix("RESULT ") }) {
    print("vitest ran: \(line)")
} else {
    let started = result.out.contains("RUN")
    print("vitest reaches the worker handshake and stops: pool started=\(started), "
          + "exit=\(result.status) — an unsettled top-level await, the worker never answering "
          + "ready. Instrumenting the worker entry shows it producing NOTHING, not even its "
          + "first line, while the fork reports no error and no exit. Ruled out by isolated "
          + "replication: the message shape, two messages back to back, the fork options, a "
          + "replaced environment, a parent suspended in top-level await, eight concurrent "
          + "children, and the dot segments in tinypool's worker path. Seven engine defects were "
          + "found on the way and are gated in workerwire and childspawn.")
}
try? FileManager.default.removeItem(at: base)
