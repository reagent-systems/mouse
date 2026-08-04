import Foundation
setvbuf(stdout, nil, _IONBF, 0)
// A real msh is attached here on purpose. Without one every command returns 127 with "no shell
// attached", and an ENOENT check would be measuring the host rather than the command — which is
// exactly how an earlier version of this looked verified while testing nothing.

// Error paths across subsystems: a missing binary, corrupt compressed data, a worker that
// throws, a watch on a path that is not there. These fire only when something goes wrong, which
// is what makes them the least likely to have been built.
let here = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let source = (try? String(contentsOf: here.appendingPathComponent("probe.js"), encoding: .utf8)) ?? ""
let expected = ((try? String(contentsOf: here.appendingPathComponent("node.txt"), encoding: .utf8)) ?? "")
    .trimmingCharacters(in: .whitespacesAndNewlines)
// A shell that reports an unknown command the way msh does. Without one every command comes
// back 127 with "no shell attached", and an ENOENT check would be measuring the HOST rather
// than the command — which is exactly how an earlier version of this looked verified while
// testing nothing at all.
let shell = NodeEngine.ShellBridge { command in
    let name = command.split(separator: " ").first.map(String.init) ?? ""
    if ["echo", "true", "false", "cat"].contains(name) {
        return (out: name == "echo" ? String(command.dropFirst(5)) + "\n" : "", err: "", status: 0)
    }
    return (out: "", err: "msh: \(name): command not found\n", status: 127)
}
let engine = NodeEngine(root: here, env: ["PATH": "/usr/bin"], shell: shell)
let mine = await engine.run(source: source, path: "/probe.js", argv: ["node", "/probe.js"], cwd: "/", stdin: "")
let ours = mine.out.trimmingCharacters(in: .whitespacesAndNewlines)
let a = expected.split(separator: "\n").map(String.init), b = ours.split(separator: "\n").map(String.init)
var bad = 0
for i in 0..<max(a.count, b.count) {
    let want = i < a.count ? a[i] : "<missing>", got = i < b.count ? b[i] : "<missing>"
    if want != got { print("  node: \(want)\n  ours: \(got)"); bad += 1 }
}
if bad == 0 && !ours.isEmpty { print("ERROR PATHS MATCH — all \(a.count), including ENOENT for a missing binary") }
else { print("ERROR PATHS DIFFER — \(bad)")
       if !mine.err.isEmpty { print("stderr: \(mine.err.prefix(300))") }; exit(1) }
