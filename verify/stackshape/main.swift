import Foundation
setvbuf(stdout, nil, _IONBF, 0)
// The SHAPE of error.stack, against real node.
//
// V8 writes "TypeError: message" and then "    at fn (file:line:col)". JSC writes the frames
// alone, "fn@file:line:col", with no first line — so on this engine every tool that logs
// `err.stack` printed frames and no reason. SvelteKit's format_server_error prints exactly that
// and nothing else; vite's ssrRewriteStacktrace matches `/^ {4}at /` and so mapped no SSR frame
// back to its source. Errors JavaScript constructs are now V8-shaped.
//
// Only comparable facts are printed — booleans, headers, names. Absolute paths and column
// numbers differ between engines by nature, and `verify/stackline` is where line numbers are
// compared.
let realNode = "/Users/thyfriendlyfox/.local/bin/node"
let base = FileManager.default.temporaryDirectory
    .appendingPathComponent("stackshape-\(ProcessInfo.processInfo.processIdentifier)")
try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: base) }

let script = """
const show = [];
function inner() { throw new TypeError('made by js'); }
function outer() { inner(); }
try { outer(); } catch (e) {
  const lines = String(e.stack).split('\\n');
  show.push('header        ' + lines[0]);
  show.push('frame is v8   ' + /^ {4}at /.test(lines[1]));
  show.push('frame is inner ' + /^ {4}at inner[ (]/.test(lines[1]));
  show.push('no ctor frame ' + !/Wrapped|__mouseError|Reflect/.test(String(e.stack)));
}
// Every constructor the language defines, each keeping its own name in the header.
for (const Kind of [Error, EvalError, RangeError, ReferenceError, SyntaxError, TypeError, URIError]) {
  show.push('kind ' + Kind.name + ' ' + String(new Kind('boom').stack).split('\\n')[0]);
}
show.push('no message    ' + JSON.stringify(String(new Error().stack).split('\\n')[0]));
// The object is still an error in every way code tests for.
show.push('instanceof    ' + (new TypeError('x') instanceof TypeError) + ' ' + (new TypeError('x') instanceof Error));
show.push('constructor   ' + (new Error('x').constructor === Error));
show.push('proto chain   ' + (Object.getPrototypeOf(TypeError) === Error));
show.push('names         ' + TypeError.name + ' ' + new TypeError('x').name);
// Subclassing, which is how every library defines its own error type.
class HttpError extends Error { constructor(m) { super(m); this.name = 'HttpError'; } }
const sub = new HttpError('not found');
show.push('subclass      ' + (sub instanceof HttpError) + ' ' + (sub instanceof Error) + ' ' + String(sub.stack).split('\\n')[0]);
// vite's rebindErrorStacktrace reads the descriptor and then overwrites; both branches must work.
const one = new Error('a');
const descriptor = Object.getOwnPropertyDescriptor(one, 'stack');
show.push('descriptor    configurable=' + descriptor.configurable + ' enumerable=' + descriptor.enumerable);
one.stack = 'replaced';
show.push('settable      ' + one.stack);
const two = new Error('b');
Object.defineProperty(two, 'stack', { value: 'redefined', configurable: true, writable: true });
show.push('redefinable   ' + two.stack);
// A cause chain still prints, and `throw` still carries the object unchanged.
show.push('cause         ' + (new Error('outer', { cause: new Error('inner') }).cause.message));
console.log(show.join('\\n'));
"""
try? script.write(to: base.appendingPathComponent("probe.js"), atomically: true, encoding: .utf8)

let process = Process()
process.executableURL = URL(fileURLWithPath: realNode)
process.arguments = ["probe.js"]
process.currentDirectoryURL = base
let pipe = Pipe()
process.standardOutput = pipe
process.standardError = Pipe()
try? process.run()
let nodeText = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
process.waitUntilExit()

let engine = NodeEngine(root: base, env: ["PATH": "/usr/bin"])
let mine = await engine.run(source: script, path: engine.namedRoot + "/probe.js",
                            argv: ["node", "probe.js"], cwd: engine.namedRoot, stdin: "")

func lines(_ text: String) -> [String] {
    text.trimmingCharacters(in: .whitespacesAndNewlines)
        .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
}
let theirs = lines(nodeText), ours = lines(mine.out)
var wrong = 0
for i in 0..<max(theirs.count, ours.count) {
    let want = i < theirs.count ? theirs[i] : "<missing>"
    let got = i < ours.count ? ours[i] : "<missing>"
    if want != got { wrong += 1; print("  node: \(want)\n  ours: \(got)") }
}
if wrong == 0 && !ours.isEmpty {
    print("STACK SHAPE MATCH — \(theirs.count) facts identical to node: the header, V8 frames, "
          + "the constructor's own frame absent, subclasses, and a stack that is still "
          + "configurable and settable")
} else {
    print("STACK SHAPE: \(wrong) of \(max(theirs.count, ours.count)) lines differ — MISMATCH")
    if !mine.err.isEmpty { print("stderr: \(mine.err.prefix(600))") }
    exit(1)
}
