import Foundation
setvbuf(stdout, nil, _IONBF, 0)
let here = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let src = (try? String(contentsOf: here.appendingPathComponent("bufprobe.js"), encoding: .utf8)) ?? ""
let engine = NodeEngine(root: here, env: ["PATH": "/usr/bin"])
let r = await engine.run(source: src, path: "/b.js", argv: ["node", "/b.js"], cwd: "/", stdin: "")
print(r.out); if !r.err.isEmpty { print("stderr: \(r.err.prefix(300))") }
