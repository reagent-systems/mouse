import Foundation
setvbuf(stdout, nil, _IONBF, 0)
let script = """
const fs = require('fs');
console.error('typeof fs.watch = ' + typeof fs.watch);
try {
  fs.writeFileSync('a.txt', 'x');
  const w = fs.watch('a.txt', (t, n) => console.error('EVENT ' + t + ' ' + n));
  console.error('watcher created, id=' + w._id);
  setTimeout(() => { fs.writeFileSync('a.txt', 'y'); }, 200);
  setTimeout(() => { w.close(); console.error('closed'); }, 700);
} catch (error) {
  console.error('THREW ' + error.name + ': ' + error.message);
  console.error(String(error.stack).split('\\n').slice(0,3).join(' | '));
}
"""
let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wprobe-\(getpid())")
try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
let engine = NodeEngine(root: dir, env: [:])
let r = await engine.run(source: script, path: "/main.js", argv: ["node", "/main.js"], cwd: "/", stdin: "")
print("stdout: \(r.out.debugDescription)\nstderr:\n\(r.err)status \(r.status)")
