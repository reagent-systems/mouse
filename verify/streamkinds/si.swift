import Foundation
setvbuf(stdout, nil, _IONBF, 0)
let here = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let src = (try? String(contentsOf: here.appendingPathComponent("stdintest.js"), encoding: .utf8)) ?? ""
let e = NodeEngine(root: here, env: ["PATH": "/usr/bin"])
let r = await e.run(source: src, path: "/si.js", argv: ["node", "/si.js"], cwd: "/", stdin: "hello piped\n")
print(r.out); if !r.err.isEmpty { print("err: \(r.err.prefix(200))") }
