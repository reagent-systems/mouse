import Foundation
setvbuf(stdout, nil, _IONBF, 0)

// Where a Rust-native npm package stops, now that `node:wasi` exists. Every napi-rs package
// publishes a `wasm32-wasi` build for platforms it ships no binary for, and its loader reaches
// that build only when told to — on iOS the native branch can never load, so the engine sets
// napi-rs's own `NAPI_RS_FORCE_WASI` by default. This measures how far that gets, on two
// packages that share nothing but their build system.
//
// The answer is one wall, and it is not ours: these builds are compiled with THREADS, and a
// wasm module declaring shared memory does not parse in JavaScriptCore (see the sharedmem
// gate — the Memory constructor accepts `shared: true` and lies about it). WASI itself is
// complete and gated separately. A single-threaded wasi build — which is what §4's CPython
// plan needs — is on the other side of this line, not behind it.

let base = FileManager.default.temporaryDirectory.appendingPathComponent("napi-\(getpid())")
try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

struct Case { let name: String; let scope: String; let probe: String }
let cases = [
    Case(name: "oxc-parser", scope: "@oxc-parser",
         probe: "require('oxc-parser').parseSync('a.ts', 'const x: number = 1;')"),
    Case(name: "rolldown", scope: "@rolldown",
         probe: "require('rolldown')"),
]

var failures = 0
for item in cases {
    let dir = base.appendingPathComponent(item.name)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    do { _ = try await PackageManager.install(requirements: [item.name: "latest"], into: dir) }
    catch { print("\(item.name): install failed: \(error)"); failures += 1; continue }

    let installed = (try? FileManager.default.contentsOfDirectory(
        atPath: dir.appendingPathComponent("node_modules/\(item.scope)").path)) ?? []
    let hasWasi = installed.contains { $0.hasSuffix("wasm32-wasi") }

    let script = """
    try { \(item.probe); console.log('loaded'); }
    catch (error) {
      const chain = []; let cause = error;
      while (cause) { chain.push(String(cause.message || cause).split('\\n')[0]); cause = cause.cause; }
      console.log('chain:', chain.join(' <- '));
    }
    """
    let engine = NodeEngine(root: dir, env: ["PATH": "/", "HOME": "/"])
    let result = await engine.run(source: script, path: "/p.cjs", argv: ["node", "/p.cjs"], cwd: "/", stdin: "")
    let text = result.out.trimmingCharacters(in: .whitespacesAndNewlines)

    // Three claims per package: the portable build was installed, the loader REACHED it (which
    // is what the flag buys), and what stopped it is shared memory.
    let reached = text.contains("shared memory is not enabled")
    print("\(item.name): wasi build installed=\(hasWasi), loader reached it=\(reached)")
    if !hasWasi || !reached {
        failures += 1
        print("  \(text.prefix(300))")
    }
}

if failures == 0 {
    print("NAPI WASI MATCH — both packages' WebAssembly builds install and their loaders reach "
          + "them; what stops both is wasm threads, which JavaScriptCore does not enable")
} else {
    print("MISMATCH: \(failures) of \(cases.count) — the napi-rs wall moved, re-read where it is now")
    exit(1)
}
try? FileManager.default.removeItem(at: base)
