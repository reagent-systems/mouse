import Foundation
setvbuf(stdout, nil, _IONBF, 0)

// Two remaining shape gaps, judged by what actually breaks rather than by property count:
// process.stdout is a hand-built object rather than a Writable (so can it be piped TO?), and
// http.Server lacks closeAllConnections/closeIdleConnections (so does close() ever finish?).
let here = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let source = (try? String(contentsOf: here.appendingPathComponent("script.js"), encoding: .utf8)) ?? ""

let p = Process()
p.executableURL = URL(fileURLWithPath: "/Users/thyfriendlyfox/.local/bin/node")
p.arguments = ["script.js"]
p.currentDirectoryURL = here
let out = Pipe()
p.standardOutput = out
p.standardError = Pipe()
try? p.run()
let expected = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    .trimmingCharacters(in: .whitespacesAndNewlines)
p.waitUntilExit()

let engine = NodeEngine(root: here, env: ["PATH": "/usr/bin"])
let mine = await engine.run(source: source, path: "/script.js",
                            argv: ["node", "/script.js"], cwd: "/", stdin: "")
let ours = mine.out.trimmingCharacters(in: .whitespacesAndNewlines)
print("---- node ----\n\(expected)\n---- ours ----\n\(ours)")
if !mine.err.isEmpty { print("stderr: \(mine.err.prefix(400))") }
print(ours == expected ? "\nMATCH" : "\nDIFFERS")
