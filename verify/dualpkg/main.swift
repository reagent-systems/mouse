import Foundation
setvbuf(stdout, nil, _IONBF, 0)

// Conditional "exports" — which FILE a specifier reaches. Node picks by the syntax of the
// request, not by the format of the file making it: `require('x')` sees the "require"
// condition, `import 'x'` and `import('x')` see "import", and import() keeps that even from
// a CommonJS file. A dual package ships genuinely different code behind those two, so getting
// it wrong is not a detail: it is why vite loaded its deprecated CJS shim and why eslint could
// not reach @humanfs/node, which publishes an "import" condition and nothing else.
//
// Subpath keys and `*` patterns are the other half. `rollup/parseAst` is not a path — there is
// no such file — it is a key in rollup's map, and vite asks for it on the first line.

let realNode = "/Users/thyfriendlyfox/.local/bin/node"
let base = FileManager.default.temporaryDirectory.appendingPathComponent("dualpkg-\(getpid())")
try? FileManager.default.removeItem(at: base)
let pkg = base.appendingPathComponent("node_modules/dual")
try? FileManager.default.createDirectory(at: pkg.appendingPathComponent("files"), withIntermediateDirectories: true)

func put(_ text: String, _ name: String, _ dir: URL) {
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try? text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
}

put("""
{
  "name": "dual",
  "version": "1.0.0",
  "main": "./legacy.cjs",
  "exports": {
    ".":            { "types": "./x.d.ts", "import": "./root.mjs", "require": "./root.cjs" },
    "./sub":        { "import": "./sub.mjs", "require": "./sub.cjs" },
    "./only-esm":   { "import": "./only.mjs" },
    "./deep/*":     "./files/*.mjs",
    "./package.json": "./package.json"
  }
}
""", "package.json", pkg)
put("export const who = 'root.mjs';\n", "root.mjs", pkg)
put("module.exports = { who: 'root.cjs' };\n", "root.cjs", pkg)
put("export const who = 'sub.mjs';\n", "sub.mjs", pkg)
put("module.exports = { who: 'sub.cjs' };\n", "sub.cjs", pkg)
put("export const who = 'only.mjs';\n", "only.mjs", pkg)
put("export const who = 'files/one.mjs';\n", "one.mjs", pkg.appendingPathComponent("files"))
put("module.exports = { who: 'legacy.cjs' };\n", "legacy.cjs", pkg)

// One program, both syntaxes. `report` keeps a failure as DATA so the two engines can be
// compared on their failures too — a specifier that must not resolve is as much of a claim.
let commonJS = """
async function report(label, load) {
  try { const m = await load(); console.log(label, '->', (m && (m.who || (m.default && m.default.who))) || JSON.stringify(m)); }
  catch (error) { console.log(label, '-> ERROR', error.code || error.message.slice(0, 40)); }
}
(async () => {
  await report('require(dual)', () => require('dual'));
  await report('require(dual/sub)', () => require('dual/sub'));
  await report('require(dual/deep/one)', () => require('dual/deep/one'));
  await report('require(dual/only-esm)', () => require('dual/only-esm'));
  await report('require(dual/files/one.mjs)', () => require('dual/files/one.mjs'));
  await report('import(dual) from cjs', () => import('dual'));
  await report('import(dual/only-esm) from cjs', () => import('dual/only-esm'));
})();
"""
let esm = """
import * as root from 'dual';
import * as sub from 'dual/sub';
import * as deep from 'dual/deep/one';
import * as only from 'dual/only-esm';
console.log('import dual ->', root.who);
console.log('import dual/sub ->', sub.who);
console.log('import dual/deep/one ->', deep.who);
console.log('import dual/only-esm ->', only.who);
const dynamic = await import('dual');
console.log('import(dual) from esm ->', dynamic.who);
"""

func runReal(_ source: String, _ name: String) -> String {
    put(source, name, base)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: realNode)
    process.arguments = [name]
    process.currentDirectoryURL = base
    let out = Pipe(), err = Pipe()
    process.standardOutput = out
    process.standardError = err
    try? process.run()
    let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    let problems = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    if !problems.isEmpty { print("real stderr (\(name)): \(problems.prefix(300))") }
    return text
}

var failures = 0
for (source, name) in [(commonJS, "probe.cjs"), (esm, "probe.mjs")] {
    let real = runReal(source, name)
    put(source, name, base)
    let engine = NodeEngine(root: base, env: ["PATH": "/"])
    let ours = await engine.run(source: source, path: "/" + name, argv: ["node", "/" + name], cwd: "/", stdin: "")
    if ours.out == real, !real.isEmpty {
        print("\(name): \(real.components(separatedBy: "\n").filter { !$0.isEmpty }.count) specifiers resolved as node resolves them")
    } else {
        failures += 1
        print("MISMATCH \(name)\n  ---- ours ----\n\(ours.out)\(ours.err.prefix(600))  ---- real ----\n\(real)")
    }
}

if failures == 0 {
    print("EXPORTS MATCH — every specifier reached the same file real node reaches, across both syntaxes")
} else {
    print("FAIL: \(failures) of 2 programs resolved differently")
    exit(1)
}
try? FileManager.default.removeItem(at: base)
