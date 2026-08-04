import Foundation
setvbuf(stdout, nil, _IONBF, 0)

// Vite's dev server on our engine — the tool the target population actually reaches for, and
// the broadest single exercise available after webpack: ESM-only source through our ESM→CJS
// rewrite, conditional "exports" resolved on the IMPORT condition, subpath exports
// (`rollup/parseAst`), an http server on our sockets, and a 2.1 MB bundled chunk that has to
// parse. The gate is what a browser would receive: real node's vite and our vite must serve
// byte-identical transformed modules for the same requests.
//
// Rollup's native parser is a .node addon, which iOS can never load; rollup publishes
// @rollup/wasm-node as its drop-in for exactly that case, and it is what the package layout
// here uses — for BOTH engines, so the comparison is between engines and not between parsers.

let realNode = "/Users/thyfriendlyfox/.local/bin/node"
let base = FileManager.default.temporaryDirectory.appendingPathComponent("vite-\(getpid())")
try? FileManager.default.removeItem(at: base)
try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

print("installing vite with our own package manager…")
do { _ = try await PackageManager.install(requirements: ["vite": "^5.4.0"], into: base) }
catch { print("FAIL: install: \(error)"); exit(1) }

let modules = base.appendingPathComponent("node_modules")
// Both of vite's native dependencies are supposed to be per-platform binaries, and iOS has
// neither. The package manager substitutes the WebAssembly build their own authors publish,
// under the original name, so vite is unmodified and never learns the difference — asserted
// here rather than assumed, because the whole build rests on it.
for (native, wasm) in [("rollup", "@rollup/wasm-node"), ("esbuild", "esbuild-wasm")] {
    let json = modules.appendingPathComponent(native + "/package.json")
    guard let data = try? Data(contentsOf: json),
          let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          parsed["name"] as? String == wasm else {
        print("FAIL: node_modules/\(native) is not \(wasm) — the substitution did not happen")
        exit(1)
    }
}
print("substituted: rollup → @rollup/wasm-node, esbuild → esbuild-wasm")

// The project lives in a DIRECTORY under the workspace, which is where a real one lives. At
// the workspace root itself vite's own "is this id inside root?" test compares against "//"
// and serves everything through its /@id/ escape hatch — its behaviour for a root of "/",
// not ours, and not the layout any project has.
let app = base.appendingPathComponent("app")
try? FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
let sources = app.appendingPathComponent("src")
try? FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
func put(_ text: String, _ path: String, _ dir: URL) {
    try? text.write(to: dir.appendingPathComponent(path), atomically: true, encoding: .utf8)
}
put(#"{ "name": "proof", "private": true, "type": "module" }"#, "package.json", app)
put("""
    import { greet } from './greet.js';
    import { VERSION } from './meta.js';
    export const banner = greet('mouse') + ' v' + VERSION;
    console.log(banner);
    """, "main.js", sources)
put("export function greet(name) { return `hello ${name}`; }\n", "greet.js", sources)
put("export const VERSION = '1.0.0';\n", "meta.js", sources)
put("<!doctype html><script type=\"module\" src=\"/src/main.js\"></script>\n", "index.html", app)

// The same program on both engines. CI=true because vite treats stdin's 'end' as a shutdown
// signal, and a harness has no terminal to hold it open on either side.
let runner = """
process.env.CI = 'true';
const { createServer } = require('vite');
(async () => {
  const server = await createServer({
    root: process.cwd(),
    logLevel: 'silent',
    server: { port: PORT, host: '127.0.0.1', hmr: false },
    optimizeDeps: { noDiscovery: true, include: [] },
  });
  await server.listen();
  for (const path of ['/src/main.js', '/src/greet.js', '/src/meta.js']) {
    const response = await fetch('http://127.0.0.1:PORT' + path);
    console.log(path, response.status, response.headers.get('content-type'));
    console.log((await response.text()).trim());
  }
  await server.close();

  // And the other half of the tool: a production build. This is rollup — in WebAssembly —
  // parsing, tree-shaking and emitting through our engine, with the bundle compared byte for
  // byte against the one real node's vite writes.
  const { build } = require('vite');
  await build({
    root: process.cwd(),
    logLevel: 'silent',
    build: {
      write: true,
      minify: false,
      lib: { entry: 'src/main.js', formats: ['es'], fileName: () => 'bundle.js' },
      rollupOptions: { output: { sourcemap: false } },
    },
  });
  const built = require('fs').readFileSync('dist/bundle.js', 'utf8');
  console.log('built bytes:', built.length);
  console.log(built.trim());
})().catch((error) => { console.log('FATAL:', error && error.stack || error); });
"""

// Real node first, in its own copy of the tree, so neither run can see the other's work.
let realDir = base.appendingPathComponent("real/app")
try? FileManager.default.createDirectory(at: realDir, withIntermediateDirectories: true)
try? FileManager.default.createSymbolicLink(atPath: base.appendingPathComponent("real/node_modules").path,
                                            withDestinationPath: modules.path)
try? FileManager.default.copyItem(at: sources, to: realDir.appendingPathComponent("src"))
put(#"{ "name": "proof", "private": true, "type": "module" }"#, "package.json", realDir)
put("<!doctype html><script type=\"module\" src=\"/src/main.js\"></script>\n", "index.html", realDir)
put(runner.replacingOccurrences(of: "PORT", with: "5311"), "serve.cjs", realDir)

let real = Process()
real.executableURL = URL(fileURLWithPath: realNode)
real.arguments = ["serve.cjs"]
real.currentDirectoryURL = realDir
let realOut = Pipe(), realErr = Pipe()
real.standardOutput = realOut
real.standardError = realErr
try? real.run()
let realText = String(decoding: realOut.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
let realProblems = String(decoding: realErr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
real.waitUntilExit()
if !realProblems.isEmpty { print("real stderr: \(realProblems.prefix(500))") }

// Then ours, on a different port so a stray listener cannot answer for the other.
let source = runner.replacingOccurrences(of: "PORT", with: "5312")
put(source, "serve.cjs", app)
let engine = NodeEngine(root: base, env: ["PATH": "/", "CI": "true"])
let ours = await engine.run(source: source, path: "/app/serve.cjs", argv: ["node", "/app/serve.cjs"], cwd: "/app", stdin: "")
if !ours.err.isEmpty { print("ours stderr: \(ours.err.prefix(2000))") }

// Vite stamps the port into what it serves, so compare with the ports normalised away.
func normalise(_ text: String) -> String {
    text.replacingOccurrences(of: "5311", with: "PORT").replacingOccurrences(of: "5312", with: "PORT")
}
let ourLines = normalise(ours.out), realLines = normalise(realText)
if ourLines == realLines, realLines.contains("200 text/javascript"), realLines.contains("hello ${name}"),
   realLines.contains("built bytes:") {
    let served = realLines.components(separatedBy: "\n").filter { $0.hasPrefix("/src/") }.count
    print("VITE MATCH — our engine ran vite's dev server (\(served) modules) AND its rollup-wasm "
          + "production build, byte-identically to real node's vite")
} else {
    print("---- ours ----\n\(ourLines)\n---- real ----\n\(realLines)")
    print("MISMATCH: vite served different bytes")
    exit(1)
}
try? FileManager.default.removeItem(at: base)
