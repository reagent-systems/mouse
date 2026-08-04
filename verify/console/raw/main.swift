import Foundation
setvbuf(stdout, nil, _IONBF, 0)
let here = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let src = (try? String(contentsOf: here.appendingPathComponent("script.js"), encoding: .utf8)) ?? ""
let e = NodeEngine(root: here, env: ["PATH": "/usr/bin"])
let r = await e.run(source: src, path: "/s.js", argv: ["node", "/s.js"], cwd: "/", stdin: "")
print("OUT:\n\(r.out)\nERR:\n\(r.err)")
