import Foundation
setvbuf(stdout, nil, _IONBF, 0)

// A project's first five minutes, as a person would spend them on a phone:
//
//     npm create vite@latest app -- --template vanilla-ts
//     cd app && npm install
//     npm run dev            → open the URL
//
// Every step is a different subsystem and they had only ever been tested apart. The scaffolder
// is a real npm package running on the engine and writing real files; the install is our own
// package manager reading the package.json it just wrote; the dev server is the phase-T
// launcher; and the proof is a request from OUTSIDE the app for a module vite compiled.

let base = FileManager.default.temporaryDirectory.appendingPathComponent("firstrun-\(getpid())")
try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

@MainActor final class Host { var program: TerminalProgram?; var exited = false }
let host = await Host()
actor Log {
    private(set) var lines: [String] = []
    func add(_ line: String) { lines.append(line) }
    func clear() { lines.removeAll() }
    func snapshot() -> [String] { lines }
}
let log = Log()

@MainActor func run(_ line: String, interactive: Bool = false) async -> (out: String, status: Int32) {
    let shell = MouseShell()
    var context = MouseShell.Context(root: base)
    context.emit = { output in Task { await log.add(output.text) } }
    context.clear = { Task { await log.clear() } }
    context.launchProgram = { program in
        host.program = program
        program.start(io: TerminalProgramIO(rows: 24, columns: 80, write: { _ in }, exit: { host.exited = true }))
    }
    let outputs = await shell.runProgram(line, context: context, interactive: interactive)
    return (outputs.map(\.text).joined(separator: "\n"), shell.lastStatus)
}

print("scaffolding…")
// vite 5, deliberately: vite 7 scaffolds with rolldown, whose binding is native, and whose
// portable build needs `node:wasi` — a core module this engine does not have. That blocker is
// PINNED at the bottom of this gate rather than described, so it cannot quietly change.
let created = await run("npm create vite@5 app -- --template vanilla-ts")
let files = (try? FileManager.default.contentsOfDirectory(atPath: base.appendingPathComponent("app").path)) ?? []
print("npm create -> status \(created.status), wrote: \(files.sorted().joined(separator: ", "))")

print("installing…")
let installed = await run("cd app && npm install")
let hasModules = FileManager.default.fileExists(atPath: base.appendingPathComponent("node_modules/vite").path)
print("npm install -> status \(installed.status), vite present: \(hasModules)")

// The scaffolded package.json's own dev script, with a port this harness can reach.
let packageFile = base.appendingPathComponent("app/package.json")
if let data = try? Data(contentsOf: packageFile),
   var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
    var scripts = json["scripts"] as? [String: String] ?? [:]
    scripts["dev"] = "vite --port 5399 --host 127.0.0.1"
    json["scripts"] = scripts
    try? JSONSerialization.data(withJSONObject: json, options: .prettyPrinted).write(to: packageFile)
}

print("starting the dev server…")
_ = await run("cd app && npm run dev", interactive: true)
try? await Task.sleep(nanoseconds: 7_000_000_000)

var served = "no answer"
do {
    let (data, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:5399/src/main.ts")!)
    let body = String(decoding: data, as: UTF8.self)
    served = "\((response as? HTTPURLResponse)?.statusCode ?? 0) \(body.count) bytes"
    if !body.isEmpty { served += body.contains("import") || body.contains("document") ? " (compiled)" : " (unexpected)" }
} catch { served = "request failed: \(error.localizedDescription)" }
print("dev server: \(served)")
let banner = await log.snapshot()
print("transcript: \(banner.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.prefix(2).joined(separator: " | "))")

await MainActor.run { host.program?.input("\u{3}") }
try? await Task.sleep(nanoseconds: 1_000_000_000)

let scaffolded = created.status == 0 && files.contains("package.json") && files.contains("index.html")
// The vite 7 story, stated as a measurement. Its bundler's wasm build INSTALLS — the package
// manager takes the `-wasm32-wasi` optional binding, which is the author's own build for
// platforms they ship no binary for — and `node:wasi` exists now, so the loader gets past that.
// What stops it is the wasm binary itself: rolldown is compiled with THREADS, and a module
// declaring shared memory does not parse in JavaScriptCore. That is a platform wall rather
// than something to write, and it is pinned so the day it moves, this says so.
_ = await run("npm install rolldown")
// The whole cause chain, not its deepest link: the loader tries every platform binary and
// then the wasm one, so the reason that matters is in the middle.
let wasiProbe = await run("node -e \"try { require('rolldown'); console.log('rolldown loaded'); } "
    + "catch (e) { const seen = []; let c = e; while (c) { seen.push(String(c.message || c)); c = c.cause; } "
    + "console.log('blocked:', seen.join(' <- ').slice(0, 700)); }\"")
print("rolldown (vite 7's bundler): \(wasiProbe.out.trimmingCharacters(in: .whitespacesAndNewlines).prefix(220))")

if scaffolded, installed.status == 0, hasModules, served.contains("200"), served.contains("compiled"),
   wasiProbe.out.contains("shared memory is not enabled") {
    print("FIRST RUN MATCH — `npm create vite` scaffolded a project, `npm install` filled it in, "
          + "and `npm run dev` served a compiled module to a client outside the app; vite 7's "
          + "rolldown gets past `node:wasi` now and is pinned on the wall behind it — its wasm "
          + "is built with threads, and shared memory is off in JavaScriptCore")
} else {
    print("MISMATCH: the first-run path")
    exit(1)
}
try? FileManager.default.removeItem(at: base)
