import Foundation
let dir = FileManager.default.temporaryDirectory.appendingPathComponent("stream-dbg")
try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
let script = """
const sp = require('stream/promises');
console.log('sp keys:', Object.keys(sp).join(','));
const { pipeline } = sp;
const { Readable, Writable } = require('stream');
const out = [];
pipeline(
  Readable.from(['p', 'q']),
  new Writable({ write(c, e, cb) { out.push(String(c)); cb(); } })
).then(() => console.log('resolved', out.join('')), (e) => console.log('rejected', e.message));
"""
let engine = NodeEngine(root: dir, env: [:])
let result = await engine.run(source: script, path: "/main.js", argv: ["node", "/main.js"], cwd: "/", stdin: "")
print("status \(result.status)\nOUT: \(result.out)ERR: \(result.err)")
