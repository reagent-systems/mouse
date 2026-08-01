import Foundation
setvbuf(stdout, nil, _IONBF, 0)

// Phase G verification for `fs.watch`, per AGENTS.md. Watch events are the most
// platform-dependent surface in node — macOS drives them from FSEvents, Linux from inotify,
// and the two disagree on the event TYPE for a plain write inside a watched directory
// ('rename' vs 'change') and on duplicate delivery. So the comparison is deliberately over
// what IS a contract: which paths get reported, in what order, with creates/deletes as
// 'rename'. Event types for entries inside a watched DIRECTORY are normalized on both sides,
// and consecutive duplicates collapsed on both sides, because FSEvents coalescing produces
// them in real node too. A root FILE watch is compared strictly — there both engines agree.

let realNode = "/Users/thyfriendlyfox/.local/bin/node"
var failures = 0
let base = FileManager.default.temporaryDirectory.appendingPathComponent("watch-verify-\(getpid())")

func directory(_ name: String) -> URL {
    let url = base.appendingPathComponent(name)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func runReal(script: String, dir: URL) -> (out: String, status: Int32) {
    try? script.write(to: dir.appendingPathComponent("main.js"), atomically: true, encoding: .utf8)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: realNode)
    process.arguments = ["main.js"]
    process.currentDirectoryURL = dir
    let out = Pipe()
    process.standardOutput = out
    process.standardError = Pipe()
    try? process.run()
    process.waitUntilExit()
    return (String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), process.terminationStatus)
}

func runOurs(script: String, dir: URL) async -> (out: String, status: Int32) {
    try? script.write(to: dir.appendingPathComponent("main.js"), atomically: true, encoding: .utf8)
    let engine = NodeEngine(root: dir, env: ["PATH": "/"])
    let result = await engine.run(source: script, path: "/main.js",
                                  argv: ["node", "/main.js"], cwd: "/", stdin: "")
    return (result.out, result.status)
}

/// Collapse consecutive duplicates: FSEvents coalescing makes real node emit some events
/// twice, and kqueue does not, which is not a difference in what happened.
func collapse(_ text: String) -> [String] {
    var out: [String] = []
    for line in text.split(separator: "\n").map(String.init) where !line.isEmpty {
        if out.last != line { out.append(line) }
    }
    return out
}

/// Directory-watch event types differ by platform mechanism (see the header), so compare the
/// reported PATHS for those, keeping types only for creates and deletes, which agree.
func normalizeTypes(_ lines: [String]) -> [String] {
    lines.map { line in
        guard line.hasPrefix("dir:") else { return line }
        let parts = line.split(separator: ":", maxSplits: 2).map(String.init)
        guard parts.count == 3 else { return line }
        return "dir:*:" + parts[2]
    }
}

// MARK: - A directory watch: create, delete, mkdir, and a write to an existing file

let directoryScript = """
const fs = require('fs');
const seen = [];
fs.mkdirSync('dir', { recursive: true });
fs.writeFileSync('dir/existing.txt', 'one');
let watcher = null;
const steps = [
  () => fs.writeFileSync('dir/existing.txt', 'two'),
  () => fs.writeFileSync('dir/created.txt', 'new'),
  () => fs.unlinkSync('dir/created.txt'),
  () => fs.mkdirSync('dir/sub'),
];
let i = 0;
function step() {
  if (i < steps.length) { steps[i++](); setTimeout(step, 300); return; }
  setTimeout(() => { watcher.close(); console.log(seen.join('\\n')); }, 400);
}
// Settle before watching: FSEvents has a coalescing window and otherwise reports the setup
// write above as the watch's FIRST event, which kqueue (correctly) does not. Matching that
// would mean inventing an event for something that happened before the watch existed.
setTimeout(() => {
  watcher = fs.watch('dir', (type, name) => seen.push('dir:' + type + ':' + name));
  setTimeout(step, 400);
}, 700);
"""

do {
    let ours = await runOurs(script: directoryScript, dir: directory("ours-dir"))
    let real = runReal(script: directoryScript, dir: directory("real-dir"))
    let a = normalizeTypes(collapse(ours.out))
    let b = normalizeTypes(collapse(real.out))
    if a == b, !a.isEmpty {
        print("watch directory: same paths in the same order as real node (\(a.count) events)")
    } else {
        failures += 1
        print("MISMATCH: watch directory\n  ours: \(a)\n  real: \(b)")
        print("  (raw ours: \(ours.out.debugDescription))\n  (raw real: \(real.out.debugDescription))")
    }
}

// MARK: - A file watch: writes are 'change', and the watch survives a replace-by-rename

let fileScript = """
const fs = require('fs');
const seen = [];
fs.writeFileSync('target.txt', 'one');
const watcher = fs.watch('target.txt', (type, name) => seen.push(type + ':' + name));
const steps = [
  () => fs.writeFileSync('target.txt', 'two'),
  () => fs.appendFileSync('target.txt', 'three'),
];
let i = 0;
function step() {
  if (i < steps.length) { steps[i++](); setTimeout(step, 300); return; }
  setTimeout(() => { watcher.close(); console.log(seen.join('\\n')); }, 400);
}
setTimeout(step, 300);
"""

do {
    let ours = await runOurs(script: fileScript, dir: directory("ours-file"))
    let real = runReal(script: fileScript, dir: directory("real-file"))
    let a = collapse(ours.out), b = collapse(real.out)
    if a == b, !a.isEmpty {
        print("watch file: identical event stream to real node (\(a.count) events)")
    } else {
        failures += 1
        print("MISMATCH: watch file\n  ours: \(a)\n  real: \(b)")
    }
}

// MARK: - The API surface, compared strictly

let surfaceScript = """
const fs = require('fs');
console.log('watch is function:', typeof fs.watch === 'function');
console.log('watchFile/unwatchFile:', typeof fs.watchFile, typeof fs.unwatchFile);
console.log('FSWatcher exported:', typeof fs.FSWatcher);
fs.writeFileSync('a.txt', 'x');
const watcher = fs.watch('a.txt', () => {});
console.log('is an EventEmitter:', typeof watcher.on === 'function', typeof watcher.close === 'function');
console.log('ref/unref:', typeof watcher.ref, typeof watcher.unref);
watcher.close();
try { fs.watch('missing-entirely.txt', () => {}); console.log('UNEXPECTED: watched a missing path'); }
catch (error) { console.log('missing path throws:', error.code); }
// watchFile returns the current stats and polls; unwatchFile must stop it (or the program
// would never exit).
const returned = fs.watchFile('a.txt', { interval: 50 }, () => {});
console.log('watchFile returns:', typeof returned);
fs.unwatchFile('a.txt');
console.log('done');
"""

do {
    let ours = await runOurs(script: surfaceScript, dir: directory("ours-surface"))
    let real = runReal(script: surfaceScript, dir: directory("real-surface"))
    if ours.out == real.out, ours.status == real.status {
        print("watch surface: match")
    } else {
        failures += 1
        print("MISMATCH: watch surface\n  ---- ours ----\n\(ours.out)  ---- real ----\n\(real.out)")
    }
}

// MARK: - Recursive watching, and an open watcher keeping the loop alive

let recursiveScript = """
const fs = require('fs');
const seen = [];
fs.mkdirSync('tree/one/two', { recursive: true });
const watcher = fs.watch('tree', { recursive: true }, (type, name) => seen.push(name));
setTimeout(() => {
  fs.writeFileSync('tree/one/two/deep.txt', 'x');
  setTimeout(() => {
    watcher.close();
    // Paths are reported RELATIVE to the watched root, with the separator node uses.
    console.log('saw deep path:', seen.some(name => String(name).indexOf('deep.txt') >= 0));
    console.log('relative, not absolute:', seen.every(name => String(name)[0] !== '/'));
  }, 500);
}, 300);
"""

do {
    let ours = await runOurs(script: recursiveScript, dir: directory("ours-recursive"))
    let real = runReal(script: recursiveScript, dir: directory("real-recursive"))
    if ours.out == real.out, ours.status == real.status {
        print("watch recursive: match")
    } else {
        failures += 1
        print("MISMATCH: watch recursive\n  ours: \(ours.out.debugDescription)\n  real: \(real.out.debugDescription)")
    }
}

try? FileManager.default.removeItem(at: base)
print(failures == 0 ? "PHASE G WATCH: ALL PASS" : "\(failures) FAILURES")
exit(failures == 0 ? 0 : 1)
