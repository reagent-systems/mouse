import Foundation
setvbuf(stdout, nil, _IONBF, 0)

// WHERE A PLACEMENT SITS, which decides whether its bins become commands.
//
// The rule is "no FURTHER node_modules below the first", and it was written as "no slash after
// node_modules/". Those agree for `chalk` and disagree for every SCOPED package, because
// `@scope/name` has a slash in the name itself. So no scoped CLI ever became a command:
// `npm i -g @anthropic-ai/claude-code` answered "added 1 packages" and left no `claude` behind.
//
// Path shapes rather than a download: this is a rule about strings, the registry cannot make it
// truer, and a gate that pulls ten megabytes to assert one boolean earns nothing.

var failures = 0
func check(_ condition: Bool, _ label: String) {
    if !condition { failures += 1; print("  FAIL: \(label)") }
}

func placement(_ path: String) -> PackageManager.Placement {
    PackageManager.Placement(
        package: PackageManager.ResolvedPackage(
            name: "x", version: "1.0.0", tarball: "", integrity: nil, shasum: nil,
            dependencies: [:], optionalDependencies: [:], bin: ["x": "cli.js"]),
        path: path)
}

let cases: [(path: String, atRoot: Bool, why: String)] = [
    ("node_modules/chalk", true, "a plain top-level package"),
    ("node_modules/@anthropic-ai/claude-code", true, "a SCOPED top-level package — the bug"),
    ("node_modules/@rollup/wasm-node", true, "the substitution this app relies on is scoped too"),
    ("node_modules/chalk/node_modules/supports-color", false, "genuinely nested"),
    ("node_modules/a/node_modules/@scope/b", false, "nested AND scoped"),
    ("node_modules/@scope/a/node_modules/b", false, "nested under a scoped parent"),
]
for item in cases {
    check(placement(item.path).atRoot == item.atRoot,
          "\(item.path) should\(item.atRoot ? "" : " not") be top level — \(item.why)")
}

if failures == 0 {
    print("SCOPED BIN: \(cases.count) placement shapes, scoped packages included — MATCH")
} else {
    print("SCOPED BIN: \(failures) of \(cases.count) failed — MISMATCH")
    exit(1)
}
