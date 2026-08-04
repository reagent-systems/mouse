import Foundation
setvbuf(stdout, nil, _IONBF, 0)

// A bundled CLI is what an installed tool usually IS, and a trace into line 4000 of its bundle
// tells a reader nothing. Every bundler emits a source map for exactly this; node reads one only
// under `--enable-source-maps`, and here it is the default, because this is an editor.
//
// The bundle is built by esbuild — the WebAssembly one, through our own package manager — so the
// map under test is a real tool's output rather than something written to be readable. Real node
// with the flag is the peer.

let realNode = "/Users/thyfriendlyfox/.local/bin/node"
let base = FileManager.default.temporaryDirectory.appendingPathComponent("bundlemap-\(getpid())")
try? FileManager.default.createDirectory(at: base.appendingPathComponent("src"), withIntermediateDirectories: true)
// esbuild's wasm build writes through the engine's fs and does not create the parent itself.
try? FileManager.default.createDirectory(at: base.appendingPathComponent("out"), withIntermediateDirectories: true)
print("installing esbuild…")
do { _ = try await PackageManager.install(requirements: ["esbuild": "^0.21.0"], into: base) }
catch { print("FAIL: install: \(error)"); exit(1) }

func put(_ text: String, _ path: String) {
    try? text.write(to: base.appendingPathComponent(path), atomically: true, encoding: .utf8)
}
put("""
    export function validate(value) {
      const trimmed = String(value).trim();
      if (!trimmed) {
        // line 5 of helper.js throws
        throw new Error('empty value');
      }
      return trimmed;
    }
    """, "src/helper.js")
put("""
    import { validate } from './helper.js';

    export function main() {
      // line 5 of entry.js calls it
      return validate('   ');
    }

    main();
    """, "src/entry.js")
put("""
    // build(), not buildSync(): the synchronous form blocks on Atomics.wait over shared
    // memory, which no separate-engine worker can ever satisfy — the engine says so by name.
    const esbuild = require('esbuild');
    esbuild.build({
      entryPoints: ['src/entry.js'],
      bundle: true,
      outfile: 'bundle.cjs',
      platform: 'node',
      format: 'cjs',
      sourcemap: SOURCEMAP,
    }).then(() => console.log('built'), (error) => console.log('build failed:', error.message));
    """, "build.cjs")

func runNode(_ arguments: [String], in directory: URL) -> (out: String, err: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: realNode)
    process.arguments = arguments
    process.currentDirectoryURL = directory
    let out = Pipe(), err = Pipe()
    process.standardOutput = out
    process.standardError = err
    try? process.run()
    let outText = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    let errText = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    return (outText, errText)
}

func linesNamed(_ text: String, _ file: String) -> [String] {
    var found: [String] = []
    for line in text.components(separatedBy: "\n") where line.contains(file) {
        if let match = line.range(of: file + #":(\d+)"#, options: .regularExpression) {
            found.append(String(line[match]).replacingOccurrences(of: file + ":", with: ""))
        }
    }
    return found
}

var failures = 0

// Two builds by esbuild ON THIS ENGINE, one carrying its map inline and one writing the map
// beside the file — into a subdirectory it creates itself, since that is what a real project's
// outfile looks like and since writing its own output is the thing that was broken.
for (label, options, outfile) in [
    ("map carried inline", "outfile: 'bundle.cjs', sourcemap: 'inline'", "bundle.cjs"),
    ("map beside the file, in a subdirectory", "outfile: 'dist/bundle.cjs', sourcemap: true", "dist/bundle.cjs"),
] {
    let builder = """
        const esbuild = require('esbuild');
        esbuild.build({
          entryPoints: ['src/entry.js'], bundle: true, platform: 'node', format: 'cjs', \(options),
        }).then(() => console.log('built'), (error) => console.log('build failed:', error.message));
        """
    put(builder, "build.cjs")
    let engine = NodeEngine(root: base, env: ["PATH": "/", "HOME": "/"])
    let built = await engine.run(source: builder, path: "/build.cjs", argv: ["node", "/build.cjs"], cwd: "/", stdin: "")
    guard built.out.contains("built"),
          let bundle = try? String(contentsOf: base.appendingPathComponent(outfile), encoding: .utf8) else {
        print("MISMATCH: \(label) — esbuild did not write it: \(built.out.prefix(160))\(built.err.prefix(160))")
        failures += 1
        continue
    }
    let mapBeside = FileManager.default.fileExists(atPath: base.appendingPathComponent(outfile + ".map").path)
    let mapInline = bundle.contains("sourceMappingURL=data:")

    let real = runNode(["--enable-source-maps", outfile], in: base)
    let ourEngine = NodeEngine(root: base, env: ["PATH": "/"])
    let ours = await ourEngine.run(source: bundle, path: "/" + outfile,
                                   argv: ["node", "/" + outfile], cwd: "/", stdin: "")
    let theirs = linesNamed(real.err, "helper.js") + linesNamed(real.err, "entry.js")
    let mine = linesNamed(ours.err, "helper.js") + linesNamed(ours.err, "entry.js")
    // And the header has to quote the SOURCE file, not the bundle.
    let quotesSource = ours.err.contains("helper.js:") && ours.err.contains("throw new Error")
    let mapWhereExpected = outfile.contains("dist") ? mapBeside : mapInline
    if mine == theirs, !theirs.isEmpty, quotesSource, mapWhereExpected {
        print("ok: \(label) -> the trace names \(theirs.joined(separator: ",")) in the source files")
    } else {
        failures += 1
        print("MISMATCH: \(label)\n  ours: \(mine)\n  node: \(theirs)\n  quotes source: \(quotesSource), map where expected: \(mapWhereExpected)")
        print("  ours raw: \(ours.err.components(separatedBy: "\n").prefix(4).joined(separator: " / ").prefix(200))")
    }
}

if failures == 0 {
    print("BUNDLE MAP MATCH — esbuild built on this engine, wrote its own output (including into "
          + "a directory it created) and its map both ways, and a trace out of the bundle names "
          + "the author's file and line, as node does with --enable-source-maps")
} else {
    print("FAIL: \(failures) of 2")
    exit(1)
}
try? FileManager.default.removeItem(at: base)
