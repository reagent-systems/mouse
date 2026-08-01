import Foundation
setvbuf(stdout, nil, _IONBF, 0)

// The line number in a stack trace, which an editor turns into a click. Everything this engine
// does to a file before running it — the CommonJS wrapper, the ESM prologue of live-export
// getters, a multi-line import collapsed to one — moves lines unless it is written not to, and
// a trace that points four lines past the throw is worse than no trace: it sends you to code
// that is fine.
//
// COLUMNS are not compared: JavaScriptCore and V8 disagree about where in an expression an
// error happens, and that is a property of the engine rather than of this transform.

let realNode = "/Users/thyfriendlyfox/.local/bin/node"
let base = FileManager.default.temporaryDirectory.appendingPathComponent("stack-\(getpid())")
try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
print("installing typescript…")
do { _ = try await PackageManager.install(requirements: ["typescript": "^5.6.0"], into: base) }
catch { print("FAIL: install: \(error)"); exit(1) }

struct Case {
    let name: String
    let file: String
    let extra: [String: String]
    /// TypeScript needs a compiler on both sides: the project's own here, and node's
    /// transform-types there.
    var typescript = false
}
let cases: [Case] = [
    Case(name: "commonjs", file: "plain.cjs", extra: [
        "plain.cjs": """
            function inner() {
              const value = 1;
              if (value) {
                // the next line is line 5
                throw new Error('boom');
              }
            }
            inner();
            """]),
    Case(name: "es module", file: "module.mjs", extra: [
        "module.mjs": """
            export const marker = 'top';
            function inner() {
              if (marker) {
                // the next line is line 5
                throw new Error('boom');
              }
            }
            inner();
            """]),
    Case(name: "multi-line import above the throw", file: "wrapped.mjs", extra: [
        "helper.mjs": "export const first = 1;\nexport const second = 2;\n",
        "wrapped.mjs": """
            import {
              first,
              second,
            } from './helper.mjs';
            // line 6 is the throw
            throw new Error('boom ' + first + second);
            """]),
    Case(name: "throw inside a callback", file: "callback.mjs", extra: [
        "callback.mjs": """
            export function run(list) {
              return list.map((item) => {
                // line 4 throws
                throw new Error('boom ' + item);
              });
            }
            run([1]);
            """]),
    // Erasing types MOVES lines, and by more than a wrapper does: four lines of interface
    // above a function simply stop existing. Without the compiler's own source map the trace
    // points that far above the throw — and the header then quotes whatever sits there.
    Case(name: "typescript with types above the throw", file: "shapes.ts", extra: [
        "shapes.ts": """
            interface Shape {
              kind: 'circle' | 'square';
              size: number;
            }

            type Handler<T> = (value: T) => void;

            export function area(shape: Shape): number {
              if (shape.size < 0) {
                // the next line is line 11
                throw new Error('negative size');
              }
              return shape.size * shape.size;
            }

            const handler: Handler<Shape> = (shape) => { area(shape); };
            handler({ kind: 'circle', size: -1 });
            """], typescript: true),
    // And the other direction: an enum EXPANDS into more lines than it occupied.
    Case(name: "typescript with an enum above the throw", file: "levels.ts", extra: [
        "levels.ts": """
            enum Level { Low = 'low', High = 'high' }

            export function check(level: Level): void {
              if (level === Level.High) {
                // line 6 throws
                throw new Error('too high');
              }
            }

            check(Level.High);
            """], typescript: true),
    Case(name: "a caught error's own stack", file: "caught.mjs", extra: [
        "caught.mjs": """
            function make() {
              // line 3 constructs it
              return new Error('made here');
            }
            const error = make();
            const frame = error.stack.split('\\n').find((line) => line.includes('caught.mjs'));
            console.log('constructed at line', frame.replace(/^.*caught\\.mjs:?/, '').split(':')[0]);
            """]),
]

func lineNumbers(_ text: String, file: String) -> [String] {
    var found: [String] = []
    for line in text.components(separatedBy: "\n") where line.contains(file) {
        if let match = line.range(of: file + #":(\d+)"#, options: .regularExpression) {
            found.append(String(line[match]).replacingOccurrences(of: file + ":", with: ""))
        }
    }
    return found
}

var failures = 0
for item in cases {
    let directory = base.appendingPathComponent(item.name.replacingOccurrences(of: " ", with: "-"))
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    // A TypeScript case needs the compiler reachable from where the file lives.
    if item.typescript {
        try? FileManager.default.createSymbolicLink(
            atPath: directory.appendingPathComponent("node_modules").path,
            withDestinationPath: base.appendingPathComponent("node_modules").path)
    }
    for (name, text) in item.extra {
        try? text.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: realNode)
    process.arguments = (item.typescript ? ["--experimental-transform-types", "--no-warnings"] : []) + [item.file]
    process.currentDirectoryURL = directory
    let out = Pipe(), err = Pipe()
    process.standardOutput = out
    process.standardError = err
    try? process.run()
    let realOut = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    let realErr = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()

    let engine = NodeEngine(root: item.typescript ? base : directory, env: ["PATH": "/"])
    let source = try! String(contentsOf: directory.appendingPathComponent(item.file), encoding: .utf8)
    // Run it where it sits, so a TypeScript case can see the compiler above it.
    let folder = item.name.replacingOccurrences(of: " ", with: "-")
    let virtual = item.typescript ? "/\(folder)/\(item.file)" : "/" + item.file
    let ours = await engine.run(source: source, path: virtual,
                                argv: ["node", virtual], cwd: item.typescript ? "/\(folder)" : "/", stdin: "")

    // Either the trace names the lines, or the program printed one itself.
    let theirs = realErr.contains(item.file) ? lineNumbers(realErr, file: item.file)
                                             : [realOut.trimmingCharacters(in: .whitespacesAndNewlines)]
    let mine = ours.err.contains(item.file) ? lineNumbers(ours.err, file: item.file)
                                            : [ours.out.trimmingCharacters(in: .whitespacesAndNewlines)]
    if !theirs.isEmpty, mine == theirs {
        print("ok: \(item.name) -> \(theirs.joined(separator: ","))")
    } else {
        failures += 1
        print("MISMATCH: \(item.name)\n  ours: \(mine)\n  node: \(theirs)")
    }
}

if failures == 0 {
    print("STACK LINE MATCH — every frame names the line node names, through the CommonJS "
          + "wrapper, the ESM prologue, a multi-line import collapsed to one, and TypeScript "
          + "erasure that moves lines both ways")
} else {
    print("FAIL: \(failures) of \(cases.count) point somewhere else")
    exit(1)
}
try? FileManager.default.removeItem(at: base)
