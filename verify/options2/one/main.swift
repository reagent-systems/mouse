import Foundation
setvbuf(stdout, nil, _IONBF, 0)
let here = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let src = (try? String(contentsOf: here.appendingPathComponent("one.js"), encoding: .utf8)) ?? ""
let which = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "encoding"
let e = NodeEngine(root: here, env: ["PATH": "/Users/thyfriendlyfox/.local/bin:/usr/bin:/bin"])
let r = await e.run(source: src, path: "/one.js", argv: ["node", "/one.js", which], cwd: "/", stdin: "")
print("out: \(r.out.trimmingCharacters(in: .whitespacesAndNewlines))")
if !r.err.isEmpty { print("err: \(r.err.prefix(200))") }
