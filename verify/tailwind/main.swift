import Foundation
setvbuf(stdout, nil, _IONBF, 0)
// Tailwind, and WHICH tailwind, because the answer differs by major version and the difference
// is not ours to fix.
//
// Tailwind 4 cannot run here. `@tailwindcss/oxide` is a napi-rs binding whose wasi build declares
// SHARED memory, JavaScriptCore refuses to parse such a module ("shared memory is not enabled"),
// and the option gating it — `JSC::Options::useSharedArrayBuffer` — is restricted in Apple's
// build: settable by name, still false in `JSC_dumpOptions`. That is a platform wall, and it
// bounds every napi-rs wasi binding built with threads.
//
// Tailwind 3 has no native half at all — the scanner and the compiler are JavaScript — so it runs.
// A user who wants tailwind on a phone today wants version 3, and that is worth pinning rather
// than leaving in a comment, because "tailwind does not work" is a coarser claim than the truth
// and would send someone away who could have shipped.
var failures = 0
func check(_ condition: Bool, _ label: String) {
    if !condition { failures += 1; print("  FAIL: \(label)") }
}

let base = FileManager.default.temporaryDirectory
    .appendingPathComponent("tailwind-\(ProcessInfo.processInfo.processIdentifier)")
try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: base) }

do { _ = try await PackageManager.install(requirements: ["tailwindcss": "^3.4.0"], into: base) }
catch {
    print("  FAIL: install threw: \(error)")
    print("TAILWIND: MISMATCH")
    exit(1)
}

// No native half to be missing: tailwind 3 ships no per-platform binary, which is the whole
// reason it runs where 4 does not. Asserted so a future version that grows one is noticed here.
let optional = (try? Data(contentsOf: base.appendingPathComponent("node_modules/tailwindcss/package.json")))
    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    .flatMap { $0["optionalDependencies"] as? [String: Any] } ?? [:]
check(optional.keys.allSatisfy { !$0.contains("darwin") && !$0.contains("wasm") },
      "tailwind 3 lists no per-platform binary: \(optional.keys.sorted())")

let script = """
const tailwind = require('tailwindcss');
const postcss = require('postcss');
// Content scanning is the part people assume cannot work: tailwind reads the markup, decides
// which utilities exist, and emits only those.
const config = {
  content: [{ raw: '<div class="mt-4 text-center font-bold md:flex hover:underline w-[37px]"></div>',
              extension: 'html' }],
  corePlugins: { preflight: false },
};
postcss([tailwind(config)])
  .process('@tailwind utilities;', { from: undefined })
  .then((result) => {
    const css = result.css.replace(/\\s+/g, ' ').trim();
    console.log('LENGTH ' + css.length);
    console.log('PLAIN ' + ['.mt-4', '.text-center', '.font-bold'].every(c => css.includes(c)));
    console.log('ARBITRARY ' + css.includes('37px'));
    console.log('VARIANT ' + (css.includes('hover\\\\:underline') || css.includes(':hover')));
    console.log('RESPONSIVE ' + css.includes('@media'));
    console.log('UNUSED ' + css.includes('.mt-8'));
  })
  .catch((e) => console.log('FAILED ' + (e && e.message || e)));
"""
let engine = NodeEngine(root: base, env: ["PATH": "/usr/bin"])
let run = await engine.run(source: script, path: engine.namedRoot + "/probe.js",
                           argv: ["node", "probe.js"], cwd: engine.namedRoot, stdin: "")
let lines = run.out.split(separator: "\n").map(String.init)
func field(_ prefix: String) -> String? {
    lines.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
}
if let failure = field("FAILED ") {
    failures += 1
    print("  FAIL: tailwind threw: \(failure)")
} else {
    check(field("PLAIN ") == "true", "the plain utilities compiled")
    check(field("ARBITRARY ") == "true", "an arbitrary value, w-[37px], compiled")
    check(field("VARIANT ") == "true", "a hover: variant compiled")
    check(field("RESPONSIVE ") == "true", "a md: variant produced a @media rule")
    // The scanner is doing its job rather than emitting everything.
    check(field("UNUSED ") == "false", "a class the markup never used was NOT emitted")
    check((Int(field("LENGTH ") ?? "0") ?? 0) > 100, "the sheet has real content: \(field("LENGTH ") ?? "0") bytes")
}
if run.out.isEmpty { failures += 1; print("  FAIL: no output — \(run.err.prefix(400))") }

if failures == 0 {
    print("TAILWIND: 7 checks — tailwind 3 scans markup and compiles utilities, variants and "
          + "arbitrary values on this engine (4 cannot: oxide's wasi build needs shared memory) — MATCH")
} else {
    print("TAILWIND: \(failures) of 7 checks failed — MISMATCH")
    exit(1)
}
