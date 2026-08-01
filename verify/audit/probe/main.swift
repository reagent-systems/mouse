import Foundation
setvbuf(stdout, nil, _IONBF, 0)
let script = """
const fs = require('fs');
const names = Object.keys(fs).sort();
console.log('have: ' + names.join(' '));
console.log('constants keys: ' + Object.keys(fs.constants || {}).sort().join(' '));
console.log('promises: ' + Object.keys(fs.promises).sort().join(' '));
"""
let dir = FileManager.default.temporaryDirectory.appendingPathComponent("aprobe-\(getpid())")
try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
let engine = NodeEngine(root: dir, env: [:])
let r = await engine.run(source: script, path: "/main.js", argv: ["node", "/main.js"], cwd: "/", stdin: "")
print(r.out)
