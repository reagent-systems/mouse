import Foundation
setvbuf(stdout, nil, _IONBF, 0)

// esbuild-wasm has been listed as proven since before today — but `Buffer.from(arrayBuffer)`
// copied instead of sharing until this session, which is exactly what wasm memory interop needs.
// So the claim was made against a broken path and has to be re-earned or corrected. esbuild is
// also the sternest wasm test available: a whole compiler inside one module, driven through a
// message protocol over shared memory.

let realNode = "/Users/thyfriendlyfox/.local/bin/node"
let base = FileManager.default.temporaryDirectory.appendingPathComponent("esbuild-\(getpid())")
try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

print("installing esbuild-wasm with our own package manager…")
do { _ = try await PackageManager.install(requirements: ["esbuild-wasm": "^0.25.0"], into: base) }
catch { print("FAIL: install: \(error)"); exit(1) }

// transform() is the single-file path; build() with stdin bundles. Both go through the wasm
// module's stdin/stdout protocol, so if memory sharing is wrong neither can work.
let script = """
const esbuild = require('esbuild-wasm');
const fs = require('fs');
async function main() {
  // In node, esbuild-wasm finds and instantiates its own module — initialize() is the browser
  // entry point, and its options are rejected here (in BOTH engines, which is how I found out).
  const transformed = await esbuild.transform('const x: number = 1; export const y = x + 1;', {
    loader: 'ts', minify: true,
  });
  console.log('transform:', JSON.stringify(transformed.code.trim()));
  const built = await esbuild.build({
    stdin: { contents: 'import {y} from "./dep.js"; console.log(y * 2);', resolveDir: '.', loader: 'js' },
    bundle: true, write: false, minify: true, format: 'cjs',
  });
  console.log('bundle:', JSON.stringify(Buffer.from(built.outputFiles[0].contents).toString().trim()));
  console.log('warnings:', built.warnings.length, 'errors:', built.errors.length);
}
main().catch(error => console.log('FAILED:', error.message));
"""

try? "export const y = 21;\n".write(to: base.appendingPathComponent("dep.js"), atomically: true, encoding: .utf8)
try? script.write(to: base.appendingPathComponent("build.js"), atomically: true, encoding: .utf8)

let real = Process()
real.executableURL = URL(fileURLWithPath: realNode)
real.arguments = ["build.js"]
real.currentDirectoryURL = base
let realOut = Pipe(), realErr = Pipe()
real.standardOutput = realOut
real.standardError = realErr
try? real.run()
real.waitUntilExit()
let realText = String(decoding: realOut.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
let realProblems = String(decoding: realErr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
if !realProblems.isEmpty { print("real stderr: \(realProblems.prefix(300))") }

let engine = NodeEngine(root: base, env: ["PATH": "/"])
let ours = await engine.run(source: script, path: "/build.js", argv: ["node", "/build.js"], cwd: "/", stdin: "")
if !ours.err.isEmpty { print("ours stderr: \(ours.err.prefix(1200))") }

print("---- ours ----\n\(ours.out)---- real ----\n\(realText)")
if ours.out == realText, !ours.out.isEmpty, !ours.out.contains("FAILED") {
    print("ESBUILD-WASM MATCH — a whole compiler in wasm transforms and bundles identically")
} else {
    print("MISMATCH: the esbuild-wasm claim does not hold as written")
    exit(1)
}
try? FileManager.default.removeItem(at: base)
