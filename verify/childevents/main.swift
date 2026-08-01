import Foundation
setvbuf(stdout, nil, _IONBF, 0)
// Found by driving jest: its file crawler waits on the child's 'exit' event, and the shell path
// emitted 'close' FIRST and never emitted 'spawn' at all.
let here = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let source = (try? String(contentsOf: here.appendingPathComponent("probe.js"), encoding: .utf8)) ?? ""
let expected = ((try? String(contentsOf: here.appendingPathComponent("node.txt"), encoding: .utf8)) ?? "")
    .trimmingCharacters(in: .whitespacesAndNewlines)
let engine = NodeEngine(root: here, env: ["PATH": "/usr/bin"])
let mine = await engine.run(source: source, path: "/probe.js", argv: ["node", "/probe.js"], cwd: "/", stdin: "")
let ours = mine.out.trimmingCharacters(in: .whitespacesAndNewlines)

// The same contract for a child bridged to msh, which is the path jest actually took.
let shell = """
const { spawn } = require('child_process');
const seen = [];
const child = spawn('echo', ['hi']);
for (const name of ['spawn', 'exit', 'close', 'error']) child.on(name, () => seen.push(name));
child.on('close', () => console.log('shell lifecycle: ' + seen.join(' ')));
"""
let e2 = NodeEngine(root: here, env: ["PATH": "/usr/bin"])
let shellRun = await e2.run(source: shell, path: "/s.js", argv: ["node", "/s.js"], cwd: "/", stdin: "")
let shellLine = shellRun.out.trimmingCharacters(in: .whitespacesAndNewlines)

var problems: [String] = []
if ours != expected { problems.append("node-child:\n  node: \(expected)\n  ours: \(ours)") }
if shellLine != "shell lifecycle: spawn exit close" { problems.append("msh-child: \(shellLine)") }
if problems.isEmpty {
    print("CHILD EVENTS MATCH — spawn, exit, close in node's order, on both child paths")
} else {
    for p in problems { print("  \(p)") }
    if !mine.err.isEmpty { print("stderr: \(mine.err.prefix(400))") }
    print("CHILD EVENTS DIFFER"); exit(1)
}
