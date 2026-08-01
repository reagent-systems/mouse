import Foundation
setvbuf(stdout, nil, _IONBF, 0)
let script = """
const fs = require('fs');
fs.mkdirSync('t/sub', { recursive: true });
fs.writeFileSync('t/f.txt', 'x');
console.error('fs.Dirent exists: ' + (typeof fs.Dirent));
console.error('fs.opendir: ' + typeof fs.opendir + ' / ' + typeof fs.opendirSync);
fs.readdir('t', { withFileTypes: true }, (error, entries) => {
  console.error('callback withFileTypes -> ' + entries.map(e => typeof e === 'string' ? 'string:' + e : e.name + ':file=' + e.isFile() + ':dir=' + e.isDirectory()).join(', '));
  const util = require('util');
  const p = util.promisify(fs.readdir);
  p('t', { withFileTypes: true }).then(list => {
    console.error('promisified -> ' + list.map(e => typeof e === 'string' ? 'string:' + e : e.name + ':file=' + e.isFile()).join(', '));
    return fs.promises.readdir('t', { withFileTypes: true });
  }).then(list => {
    console.error('fs.promises -> ' + list.map(e => typeof e === 'string' ? 'string:' + e : e.name + ':file=' + e.isFile()).join(', '));
  });
});
"""
let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cprobe-\(getpid())")
try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
let engine = NodeEngine(root: dir, env: [:])
let r = await engine.run(source: script, path: "/main.js", argv: ["node", "/main.js"], cwd: "/", stdin: "")
print("stderr:\n\(r.err)status \(r.status)")
