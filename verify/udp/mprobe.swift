import Foundation
setvbuf(stdout, nil, _IONBF, 0)
let dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let source = try! String(contentsOf: dir.appendingPathComponent("mcast.js"), encoding: .utf8)
let engine = NodeEngine(root: dir, env: ["PATH": "/"])
let r = await engine.run(source: source, path: "/mcast.js", argv: ["node", "/mcast.js", CommandLine.arguments[1]], cwd: "/", stdin: "")
print(r.out, terminator: "")
if !r.err.isEmpty { print("stderr: \(r.err.prefix(400))") }
