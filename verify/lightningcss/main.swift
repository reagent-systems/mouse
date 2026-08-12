import Foundation
setvbuf(stdout, nil, _IONBF, 0)
// lightningcss, which iOS cannot load: the package resolves `lightningcss-<platform>-<arch>` or a
// sibling `.node`, and unlike a napi-rs loader it has no wasi branch to fall back to — so it is a
// missing module, and vite reaches for it as a CSS transformer while tailwind 4 pulls it in
// through `@tailwindcss/node`. `wasmSubstitutes` installs the authors' own `lightningcss-wasm`
// under the original name.
//
// Installing it is not the claim worth gating; TRANSFORMING with it is. The wasm package has two
// faces, and only one of them is substitutable: the browser build wants `await init()` before any
// call, while the `node` export condition instantiates at module scope and hands back synchronous
// functions — the shape lightningcss's own callers require. So this runs real CSS through the
// substitute, in this engine, and checks the output is minified CSS rather than a promise.
var failures = 0
func check(_ condition: Bool, _ label: String) {
    if !condition { failures += 1; print("  FAIL: \(label)") }
}

let scratch = FileManager.default.temporaryDirectory
    .appendingPathComponent("lightningcss-\(ProcessInfo.processInfo.processIdentifier)")
defer { try? FileManager.default.removeItem(at: scratch) }
try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

do {
    _ = try await PackageManager.install(requirements: ["lightningcss": "^1.30.0"], into: scratch)
} catch {
    print("  FAIL: install threw: \(error)")
    print("LIGHTNINGCSS: install failed — MISMATCH")
    exit(1)
}

// 1. The substitute is what landed, under the original name.
let installed = scratch.appendingPathComponent("node_modules/lightningcss/package.json")
guard let data = try? Data(contentsOf: installed),
      let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
    print("  FAIL: node_modules/lightningcss has no package.json")
    print("LIGHTNINGCSS: MISMATCH")
    exit(1)
}
check(parsed["name"] as? String == "lightningcss-wasm",
      "node_modules/lightningcss is lightningcss-wasm, not \(parsed["name"] as? String ?? "?")")
check(FileManager.default.fileExists(
        atPath: scratch.appendingPathComponent("node_modules/lightningcss/lightningcss_node.wasm").path),
      "the wasm artifact came with it")

// 2. It transforms, synchronously, in this engine.
let script = """
const css = require('lightningcss');
const result = css.transform({
  filename: 'in.css',
  code: Buffer.from(['.a {', '  color: #ff0000;', '}', '.b { padding: 0px 0px 0px 0px }'].join('\\n')),
  minify: true,
});
if (result instanceof Promise) { console.log('PROMISE'); }
else { console.log('CODE ' + Buffer.from(result.code).toString('utf8')); }
console.log('FEATURES ' + typeof css.Features);
console.log('COMPOSE ' + typeof css.composeVisitors);
console.log('BUNDLE ' + typeof css.bundle);
"""
let engine = NodeEngine(root: scratch, env: ["PATH": "/usr/bin"])
let run = await engine.run(source: script, path: engine.namedRoot + "/probe.js",
                           argv: ["node", "probe.js"], cwd: engine.namedRoot, stdin: "")
let lines = run.out.split(separator: "\n").map(String.init)
func line(_ prefix: String) -> String? {
    lines.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
}
if let code = line("CODE ") {
    // Minified, both rules present, the hex colour shortened the way lightningcss does it.
    check(code.contains(".a"), "the first rule survived: \(code)")
    check(code.contains(".b"), "the second rule survived: \(code)")
    check(code.contains("red"), "#ff0000 minified to `red`: \(code)")
    check(!code.contains("\n  "), "the output is minified: \(code)")
} else {
    failures += 1
    print("  FAIL: no transform output — \(run.out.isEmpty ? run.err : run.out)")
}
check(line("FEATURES ") == "object" || line("FEATURES ") == "function", "Features is exported")
check(line("COMPOSE ") == "function", "composeVisitors is exported")
check(line("BUNDLE ") == "function", "bundle is exported")

if failures == 0 {
    print("LIGHTNINGCSS: 9 checks — the wasm build installs under the native name and transforms CSS synchronously — MATCH")
} else {
    print("LIGHTNINGCSS: \(failures) of 9 checks failed — MISMATCH")
    exit(1)
}
