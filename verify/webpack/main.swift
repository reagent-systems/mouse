import Foundation
setvbuf(stdout, nil, _IONBF, 0)

// The bundling half of phase D: webpack 5, installed by OUR package manager, bundling a real
// multi-file project on our engine — in production mode, so terser minifies too. webpack leans
// on fs, path, crypto hashing, streams, enhanced-resolve's module resolution and its own
// tapable plugin system all at once, which makes it the broadest single exercise available.
// The emitted bundle is compared byte for byte with real node's, and then RUN.

let realNode = "/Users/thyfriendlyfox/.local/bin/node"
let base = FileManager.default.temporaryDirectory.appendingPathComponent("webpack-\(getpid())")
try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

print("installing webpack with our own package manager…")
do { _ = try await PackageManager.install(requirements: ["webpack": "^5.97.0"], into: base) }
catch { print("FAIL: install: \(error)"); exit(1) }

// A project with a dependency graph worth resolving: ESM syntax, a JSON import, a nested
// directory, and a package from node_modules.
let sources = base.appendingPathComponent("src")
try? FileManager.default.createDirectory(at: sources.appendingPathComponent("math"), withIntermediateDirectories: true)
try? """
    import { total } from './math/sum.js';
    import config from './config.json';
    export function report(values) {
      return config.label + ': ' + total(values);
    }
    console.log(report([1, 2, 3, 4]));
    """.write(to: sources.appendingPathComponent("index.js"), atomically: true, encoding: .utf8)
try? """
    export function total(values) {
      return values.reduce((sum, value) => sum + value, 0);
    }
    """.write(to: sources.appendingPathComponent("math/sum.js"), atomically: true, encoding: .utf8)
try? #"{ "label": "sum" }"#.write(to: sources.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)

let runner = """
const webpack = require('webpack');
const path = require('path');
webpack({
  mode: 'production',
  entry: './src/index.js',
  output: { path: path.resolve('out'), filename: 'bundle.js' },
  target: 'node',
  // A deterministic id scheme, or the two runs would differ on hashes alone.
  optimization: { moduleIds: 'named', chunkIds: 'named' },
}, (error, stats) => {
  if (error) { console.log('FATAL:', error.message); return; }
  const info = stats.toJson({ all: false, errors: true, warnings: true, assets: true });
  console.log('errors:', info.errors.length, 'warnings:', info.warnings.length);
  if (info.errors.length) console.log(info.errors.map(e => e.message).join('\\n'));
  console.log('assets:', info.assets.map(a => a.name).join(','));
  console.log('modules bundled:', stats.compilation.modules.size);
});
"""

func write(_ text: String, _ name: String, _ dir: URL) {
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try? text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
}

// Real node first, in its own copy of the tree, so the two outputs are independent.
let realDir = base.appendingPathComponent("real")
try? FileManager.default.createDirectory(at: realDir, withIntermediateDirectories: true)
try? FileManager.default.createSymbolicLink(atPath: realDir.appendingPathComponent("node_modules").path,
                                            withDestinationPath: base.appendingPathComponent("node_modules").path)
try? FileManager.default.copyItem(at: sources, to: realDir.appendingPathComponent("src"))
write(runner, "build.js", realDir)
let real = Process()
real.executableURL = URL(fileURLWithPath: realNode)
real.arguments = ["build.js"]
real.currentDirectoryURL = realDir
let realOut = Pipe(), realErr = Pipe()
real.standardOutput = realOut
real.standardError = realErr
try? real.run()
real.waitUntilExit()
let realText = String(decoding: realOut.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
let realProblems = String(decoding: realErr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
if !realProblems.isEmpty { print("real stderr: \(realProblems.prefix(400))") }

// Then ours.
write(runner, "build.js", base)
let engine = NodeEngine(root: base, env: ["PATH": "/"])
let ours = await engine.run(source: runner, path: "/build.js", argv: ["node", "/build.js"], cwd: "/", stdin: "")
if !ours.err.isEmpty { print("ours stderr: \(ours.err.prefix(1600))") }

print("---- ours ----\n\(ours.out)---- real ----\n\(realText)")

let ourBundle = try? String(contentsOf: base.appendingPathComponent("out/bundle.js"), encoding: .utf8)
let realBundle = try? String(contentsOf: realDir.appendingPathComponent("out/bundle.js"), encoding: .utf8)

guard let ourBundle, let realBundle else {
    print("MISMATCH: a bundle is missing (ours: \(ourBundle != nil), real: \(realBundle != nil))")
    exit(1)
}
if ourBundle != realBundle {
    print("MISMATCH: bundles differ (ours \(ourBundle.count) bytes, real \(realBundle.count) bytes)")
    exit(1)
}

// And the bundle has to RUN — a byte-identical file that throws would still be a failure.
let check = Process()
check.executableURL = URL(fileURLWithPath: realNode)
check.arguments = ["out/bundle.js"]
check.currentDirectoryURL = base
let checkOut = Pipe()
check.standardOutput = checkOut
check.standardError = Pipe()
try? check.run()
check.waitUntilExit()
let ran = String(decoding: checkOut.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)

if ours.out == realText, ran.trimmingCharacters(in: .whitespacesAndNewlines) == "sum: 10" {
    print("WEBPACK MATCH — our engine emitted a byte-identical minified bundle, and it runs: \(ran.trimmingCharacters(in: .whitespacesAndNewlines))")
} else {
    print("MISMATCH: build report or bundle behavior (bundle ran as: \(ran.debugDescription))")
    exit(1)
}
try? FileManager.default.removeItem(at: base)
