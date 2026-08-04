import Foundation
setvbuf(stdout, nil, _IONBF, 0)
let here = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let src = (try? String(contentsOf: here.appendingPathComponent("probe2.js"), encoding: .utf8)) ?? ""
let e = NodeEngine(root: here, env: ["PATH": "/usr/bin"])
let r = await e.run(source: src, path: "/probe2.js", argv: ["node", "/probe2.js"], cwd: "/", stdin: "")
print(r.out); if !r.err.isEmpty { print("err: \(r.err.prefix(200))") }
