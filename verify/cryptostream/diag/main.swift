import Foundation
setvbuf(stdout, nil, _IONBF, 0)
let here = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let src = (try? String(contentsOf: here.appendingPathComponent("diag.js"), encoding: .utf8)) ?? ""
let e = NodeEngine(root: here, env: ["PATH": "/usr/bin"])
let r = await e.run(source: src, path: "/diag.js", argv: ["node", "/diag.js"], cwd: "/", stdin: "")
print("---- ours ----"); print(r.out); if !r.err.isEmpty { print("stderr: \(r.err.prefix(400))") }
