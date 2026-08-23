import Foundation
setvbuf(stdout, nil, _IONBF, 0)

// `pip install` against the REAL PyPI — pure wheels only, which is the whole contract.
//
// The on-device CPython has no pip, no ensurepip, and cannot load a compiled extension, so this
// installer exists to put pure-Python wheels where PYTHONPATH finds them and to refuse compiled
// ones in words. Real registry rather than a stub: the previous stub-shaped gate in this area
// ended up agreeing with the client about the wrong protocol, and PyPI's JSON shape is the thing
// half these checks assert.

var failures = 0
func check(_ condition: Bool, _ label: String) {
    if !condition { failures += 1; print("  FAIL: \(label)") }
}

// Name rules stand alone.
check(Pip.canonicalize("Ruamel.YAML") == "ruamel-yaml", "PEP 503: dots and case fold")
check(Pip.canonicalize("prompt__toolkit") == "prompt-toolkit", "runs of separators are one dash")
check(Pip.split("python-dotenv==1.2.2").pin == "1.2.2", "an exact pin parses")
check(Pip.split("httpx").pin == nil, "a bare name has no pin")

let target = FileManager.default.temporaryDirectory
    .appendingPathComponent("pipwheel-\(ProcessInfo.processInfo.processIdentifier)")
defer { try? FileManager.default.removeItem(at: target) }

func note(_ line: String) { print("    \(line)") }

// 1. A pinned, dependency-free wheel: the exact version lands and imports would find it.
do {
    try await Pip.install(["python-dotenv==1.2.2"], into: target, note: note)
    let module = target.appendingPathComponent("dotenv/__init__.py")
    check(FileManager.default.fileExists(atPath: module.path), "dotenv/__init__.py landed")
    let dist = target.appendingPathComponent("python_dotenv-1.2.2.dist-info/METADATA")
    check(FileManager.default.fileExists(atPath: dist.path), "the pinned version is the one installed")
} catch { failures += 1; print("  FAIL: dotenv install threw: \(error)") }

// 2. The closure: requests pulls charset-normalizer, idna, urllib3, certifi by itself.
do {
    try await Pip.install(["requests"], into: target, note: note)
    for dep in ["requests", "idna", "urllib3", "certifi", "charset_normalizer"] {
        let present = FileManager.default.fileExists(atPath: target.appendingPathComponent(dep).path)
            || FileManager.default.fileExists(atPath: target.appendingPathComponent(dep + ".py").path)
        check(present, "\(dep) arrived as part of requests' closure")
    }
} catch { failures += 1; print("  FAIL: requests install threw: \(error)") }

// 3. Idempotence: asking again is a statement, not a re-download.
do {
    var said = ""
    try await Pip.install(["requests"], into: target) { said += $0 }
    check(said.contains("already installed"), "a second install says already installed")
} catch { failures += 1; print("  FAIL: re-install threw: \(error)") }

// 4. A compiled-only package is refused IN WORDS. pydantic-core is the exact wall Hermes hits.
do {
    _ = try await Pip.install(["pydantic-core"], into: target, note: note)
    failures += 1
    print("  FAIL: pydantic-core should have been refused — it has no pure wheel")
} catch {
    check("\(error)".contains("no pure-Python wheel"),
          "the refusal names the reason: \(error)")
}

if failures == 0 {
    print("PIP WHEEL: pins, closures, idempotence and an honest refusal, against the real PyPI — MATCH")
} else {
    print("PIP WHEEL: \(failures) checks failed — MISMATCH")
    exit(1)
}
