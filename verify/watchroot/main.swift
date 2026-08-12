import Foundation
setvbuf(stdout, nil, _IONBF, 0)
// The watcher rooted at the PROJECT ROOT — the shape that took a dev server down and that no
// harness here could see.
//
// chokidar records a directory under its parent: `_getWatchedDir(dirname(dir)).add(basename(dir))`.
// For the root, POSIX says dirname is "/" and basename is "", so it filed a child named "" inside
// the root's own record; on the next read that child was missing, so it called it deleted, and
// removing "" resolved back to the root and tore the whole tree down — an `unlink` for every file
// in the project, including `vite.config.ts`. Vite restarted, built a new watcher, and did it
// again about every three seconds. `verify/chokidar` watches a SUBDIRECTORY and is green
// throughout, which is precisely why this needed its own harness.
//
// The fix is that a program starts at a NAMED root, so the path it watches has a real parent and
// a real basename. That is a property of the launch path, so this drives the actual shell rather
// than calling the engine directly.
//
// What this gate does and does not prove, stated plainly because a gate that oversells itself is
// worse than none. Running it against the previous launch path — the two sites in Shell.swift
// that passed `"/" + cwd` — fails on the root checks, so it does catch the regression that caused
// the storm. It does NOT reproduce the storm: standalone chokidar over a root of this size stayed
// quiet even from "/", and the tearing needed the dev server's own watcher and its own churn. The
// unlink assertions below are therefore an invariant being held, not a reproduction being fixed.
//
// Silence alone would be a false green — a watcher that died reports nothing either — so the run
// ends by demanding a real event.
var failures = 0
func check(_ condition: Bool, _ label: String) {
    if !condition { failures += 1; print("  FAIL: \(label)") }
}

let base = FileManager.default.temporaryDirectory
    .appendingPathComponent("watchroot-\(ProcessInfo.processInfo.processIdentifier)")
try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: base) }

print("installing chokidar…")
do { _ = try await PackageManager.install(requirements: ["chokidar": "^3.6.0"], into: base) }
catch { print("  FAIL: install: \(error)"); print("WATCH ROOT: MISMATCH"); exit(1) }

// A project shaped like a real one: a config at the root — the file whose loss restarts a dev
// server — plus nested source and an existing directory to walk.
for (name, text) in [("vite.config.ts", "export default {}"), ("package.json", "{\"name\":\"w\"}")] {
    try? text.write(to: base.appendingPathComponent(name), atomically: true, encoding: .utf8)
}
try? FileManager.default.createDirectory(at: base.appendingPathComponent("src/lib"),
                                         withIntermediateDirectories: true)
for name in ["src/main.ts", "src/lib/util.ts"] {
    try? "export const x = 1".write(to: base.appendingPathComponent(name), atomically: true, encoding: .utf8)
}

let script = """
const chokidar = require('chokidar');
const fs = require('fs');
const quiet = [];
// '.' is what a dev server watches: the project root, as the program's own cwd.
const watcher = chokidar.watch('.', {
  ignoreInitial: true,
  ignored: (p) => p.includes('node_modules'),
});
watcher.on('all', (event, where) => quiet.push(event + ' ' + where.replace(/\\\\/g, '/')));
watcher.on('ready', () => {
  console.log('CWD ' + process.cwd());
  // Writing a file into the ROOT DIRECTORY is what springs the trap: it makes chokidar re-read
  // the root's children, and only on that read does the ""-named child it filed earlier look
  // deleted. SvelteKit does exactly this — it regenerates `.svelte-kit/` beside the config on
  // every request — which is why the storm was a dev-server symptom and not a watcher demo.
  fs.mkdirSync('.svelte-kit/generated', { recursive: true });
  fs.writeFileSync('.svelte-kit/generated/root.svelte', '<div></div>');
  setTimeout(() => {
    fs.writeFileSync('src/added.ts', 'export const y = 2');
    setTimeout(async () => {
      await watcher.close();
      console.log('EVENTS ' + (quiet.length ? quiet.join(', ') : '(nothing)'));
      console.log('UNLINKS ' + quiet.filter((e) => e.startsWith('unlink')).length);
      process.exit(0);
    }, 2500);
  }, 1500);
});
"""
try? script.write(to: base.appendingPathComponent("watch.js"), atomically: true, encoding: .utf8)

@MainActor func msh(_ line: String) async -> String {
    let shell = MouseShell()
    let outputs = await shell.runProgram(line, context: MouseShell.Context(root: base),
                                         interactive: false)
    return outputs.map(\.text).joined(separator: "\n")
}
let out = await msh("node watch.js")
func field(_ prefix: String) -> String? {
    out.split(separator: "\n").map(String.init).first { $0.hasPrefix(prefix) }
        .map { String($0.dropFirst(prefix.count)) }
}

let cwd = field("CWD ") ?? "(none)"
// The root a program starts at must have a parent and a basename. "/" has neither, and that is
// the entire bug: `dirname("/")` is "/" and `basename("/")` is "".
check(cwd != "/", "a program does not start at \"/\" — it starts at \(cwd)")
// Asked of an engine over this same workspace rather than assumed: the name steps aside when the
// workspace already holds a directory of that name, so there is no single right answer to hardcode.
let expectedRoot = NodeEngine(root: base, env: [:]).namedRoot
check(cwd == expectedRoot, "the launch cwd is the named root \(expectedRoot), got \(cwd)")

let events = field("EVENTS ") ?? "(no output)"
// The storm reported every file in the project as deleted. Nothing was deleted here.
check(field("UNLINKS ") == "0", "writing into the root deletes nothing — \(events)")
check(!events.contains("unlink vite.config.ts"),
      "the config file in particular survives — losing it is what restarted the server")
// Alive, not merely silent: a watcher that died would also report no unlink.
check(events.contains("add src/added.ts"), "the watcher still reports a real add — \(events)")

if failures == 0 {
    print("WATCH ROOT: 5 checks — a project root stays watchable while it is written into — MATCH")
} else {
    print("WATCH ROOT: \(failures) of 5 checks failed — MISMATCH")
    if out.isEmpty { print("  (the program printed nothing)") } else { print("  output:\n\(out.prefix(800))") }
    exit(1)
}
