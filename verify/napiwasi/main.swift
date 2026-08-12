import Foundation
setvbuf(stdout, nil, _IONBF, 0)
// The napi-rs wasi substitution, against the REAL registry — because its old assumption expired
// in the field. `wasiBinding` used to find `…-wasm32-wasi` listed in a package's
// `optionalDependencies`; rolldown 1.x stopped listing it, and on a phone that turned
// `npm run dev` of a vite 8 project into "Cannot find native binding": the loader's wasi branch
// probes `@rolldown/binding-wasm32-wasi` by name and nothing had installed it. The binding name
// is now DERIVED from the natives' own naming shape when the listing is absent — and a derived
// name is a guess, so a package with no wasi build in the registry must install exactly as it
// always did.
//
// Three checks, one per way this can go:
//   1. rolldown (derivation case): the wasi binding lands even though it is unlisted.
//   2. a synthetic listed case: the old path still wins over derivation.
//   3. @parcel/watcher (no wasi build exists): the guessed name 404s and the install SUCCEEDS.
var failures = 0
func check(_ condition: Bool, _ label: String) {
    if !condition {
        failures += 1
        print("  FAIL: \(label)")
    }
}

let scratch = FileManager.default.temporaryDirectory
    .appendingPathComponent("napiwasi-\(ProcessInfo.processInfo.processIdentifier)")
defer { try? FileManager.default.removeItem(at: scratch) }

// 1. rolldown: natives listed, wasi unlisted — the derivation must fetch it anyway, versioned
//    in lockstep with rolldown itself.
do {
    let root = scratch.appendingPathComponent("rolldown")
    _ = try await PackageManager.install(requirements: ["rolldown": "^1.0.0"], into: root)
    let binding = root.appendingPathComponent("node_modules/@rolldown/binding-wasm32-wasi")
    check(FileManager.default.fileExists(atPath: binding.appendingPathComponent("package.json").path),
          "rolldown's unlisted wasi binding is installed by derivation")
    let wasm = binding.appendingPathComponent("rolldown-binding.wasm32-wasi.wasm")
    check(FileManager.default.fileExists(atPath: wasm.path),
          "and it is the real artifact, wasm included")
    let rolldownVersion = try packageVersion(root, "node_modules/rolldown")
    let bindingVersion = try packageVersion(root, "node_modules/@rolldown/binding-wasm32-wasi")
    check(rolldownVersion == bindingVersion,
          "binding version \(bindingVersion) is rolldown's own \(rolldownVersion) — lockstep held")
} catch {
    failures += 1
    print("  FAIL: rolldown install threw: \(error)")
}

// 2. The listed shape still takes precedence — derivation is the fallback, not a replacement.
do {
    let listed = fake(optional: [
        "@fake/binding-darwin-arm64": "9.9.9",
        "@fake/binding-wasm32-wasi": "9.9.8",
    ])
    let answer = PackageManager.wasiBinding(of: listed)
    check(answer?.name == "@fake/binding-wasm32-wasi" && answer?.derived == false
          && answer?.requirement == "9.9.8",
          "a LISTED wasi binding wins, at its listed requirement")
    let unlisted = fake(optional: ["@fake/binding-linux-x64-gnu": "9.9.9"])
    let derived = PackageManager.wasiBinding(of: unlisted)
    check(derived?.name == "@fake/binding-wasm32-wasi" && derived?.derived == true
          && derived?.requirement == "9.9.9",
          "an unlisted one derives the name and pins the package's own version")
    let plain = fake(optional: ["fsevents": "^2.0.0"])
    check(PackageManager.wasiBinding(of: plain) == nil,
          "optional deps that are not napi bindings derive nothing")
}

// 3. @parcel/watcher publishes natives and a wasm build, but nothing named `…-wasm32-wasi` —
//    the derived guess 404s in the registry, and the install must succeed regardless.
do {
    let root = scratch.appendingPathComponent("watcher")
    _ = try await PackageManager.install(requirements: ["@parcel/watcher": "^2.0.0"], into: root)
    check(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("node_modules/@parcel/watcher/package.json").path),
          "a package whose derived wasi name does not exist installs as it always did")
    check(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent("node_modules/@parcel/watcher-wasm32-wasi").path),
          "and the failed guess left nothing behind")
} catch {
    failures += 1
    print("  FAIL: @parcel/watcher install threw: \(error)")
}

func fake(optional: [String: String]) -> PackageManager.ResolvedPackage {
    PackageManager.ResolvedPackage(
        name: "fake", version: "9.9.9", tarball: "", integrity: nil, shasum: nil,
        dependencies: [:], optionalDependencies: optional, bin: [:])
}

func packageVersion(_ root: URL, _ path: String) throws -> String {
    let data = try Data(contentsOf: root.appendingPathComponent(path).appendingPathComponent("package.json"))
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    return json?["version"] as? String ?? "?"
}

if failures == 0 {
    print("NAPI WASI: 8 checks — unlisted binding derived and installed in lockstep, listed shape still wins, a 404 guess tolerated — MATCH")
} else {
    print("NAPI WASI: \(failures) of 8 checks failed — MISMATCH")
    exit(1)
}
