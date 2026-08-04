import Foundation
setvbuf(stdout, nil, _IONBF, 0)

// Real-package proof for fs.watch: chokidar, the watcher every dev tool actually uses
// (webpack, vite, nodemon, jest --watch, tsc's own watch mode via its host). Installed by OUR
// package manager, run on our engine, and compared with the same script under real node —
// chokidar normalizes platform differences itself, which is exactly why it is the right
// witness: if our fs.watch is close enough for chokidar, it is close enough for the tools.

let realNode = "/Users/thyfriendlyfox/.local/bin/node"
let base = FileManager.default.temporaryDirectory.appendingPathComponent("chokidar-\(getpid())")
try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

let script = """
const chokidar = require('chokidar');
const fs = require('fs');
const events = [];
fs.mkdirSync('tree/nested', { recursive: true });
fs.writeFileSync('tree/first.txt', 'one');
const watcher = chokidar.watch('tree', { ignoreInitial: false, awaitWriteFinish: false });
watcher.on('all', (event, path) => events.push(event + ' ' + path.replace(/\\\\/g, '/')));
watcher.on('ready', () => {
  setTimeout(() => fs.writeFileSync('tree/second.txt', 'two'), 200);
  setTimeout(() => fs.appendFileSync('tree/first.txt', 'more'), 600);
  setTimeout(() => fs.writeFileSync('tree/nested/deep.txt', 'deep'), 1000);
  setTimeout(() => fs.unlinkSync('tree/second.txt'), 1400);
  setTimeout(async () => {
    await watcher.close();
    // Sorted: chokidar's ordering across directories is not something either engine promises.
    console.log(Array.from(new Set(events)).sort().join('\\n'));
  }, 2000);
});
"""

print("installing chokidar with our own package manager…")
do { _ = try await PackageManager.install(requirements: ["chokidar": "^3.6.0"], into: base) }
catch { print("FAIL: install: \(error)"); exit(1) }

let oursDir = base
let realDir = base.appendingPathComponent("real")
try? FileManager.default.createDirectory(at: realDir, withIntermediateDirectories: true)
// The real run needs the same node_modules; a symlink keeps one download.
try? FileManager.default.createSymbolicLink(atPath: realDir.appendingPathComponent("node_modules").path,
                                            withDestinationPath: base.appendingPathComponent("node_modules").path)

try? script.write(to: oursDir.appendingPathComponent("main.js"), atomically: true, encoding: .utf8)
let engine = NodeEngine(root: oursDir, env: ["PATH": "/"])
let ours = await engine.run(source: script, path: "/main.js", argv: ["node", "/main.js"], cwd: "/", stdin: "")

try? script.write(to: realDir.appendingPathComponent("main.js"), atomically: true, encoding: .utf8)
let process = Process()
process.executableURL = URL(fileURLWithPath: realNode)
process.arguments = ["main.js"]
process.currentDirectoryURL = realDir
let out = Pipe(), err = Pipe()
process.standardOutput = out
process.standardError = err
try? process.run()
process.waitUntilExit()
let real = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)

if ours.out == real, !ours.out.isEmpty {
    print("CHOKIDAR MATCH — the watcher every dev tool uses sees the same events on our engine:")
    print(ours.out, terminator: "")
} else {
    print("MISMATCH")
    print("---- ours ----\n\(ours.out)---- ours stderr ----\n\(ours.err)---- real ----\n\(real)")
    print("---- real stderr ----\n\(String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))")
    exit(1)
}
try? FileManager.default.removeItem(at: base)
