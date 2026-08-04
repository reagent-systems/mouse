import Foundation
setvbuf(stdout, nil, _IONBF, 0)

// The heaviest real consumer of fs.watch: TypeScript's own compiler in WATCH mode, installed
// by our package manager and running on our engine. tsc --watch builds a watch host out of
// fs.watch/fs.watchFile, recompiles on change, and reports diagnostics — so this exercises the
// watcher, the module resolver, the fs surface and a 10 MB bundle at once. Compared against
// the same project under real node.

let realNode = "/Users/thyfriendlyfox/.local/bin/node"
let base = FileManager.default.temporaryDirectory.appendingPathComponent("tscwatch-\(getpid())")
try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

print("installing typescript with our own package manager…")
var binPath = ""
do {
    let report = try await PackageManager.install(requirements: ["typescript": "^5.9.0"], into: base)
    guard let tsc = report.bins["tsc"] else { print("FAIL: no tsc bin"); exit(1) }
    binPath = tsc
} catch { print("FAIL: install: \(error)"); exit(1) }

// A project whose second file is edited mid-run, so the watch has something to report.
let sources = base.appendingPathComponent("src")
try? FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
try? """
    {
      "compilerOptions": { "outDir": "out", "target": "ES2020", "module": "CommonJS", "strict": true },
      "include": ["src"]
    }
    """.write(to: base.appendingPathComponent("tsconfig.json"), atomically: true, encoding: .utf8)
try? "export const greeting: string = 'hello';\n"
    .write(to: sources.appendingPathComponent("one.ts"), atomically: true, encoding: .utf8)
try? "import { greeting } from './one';\nexport const shout = greeting.toUpperCase();\n"
    .write(to: sources.appendingPathComponent("two.ts"), atomically: true, encoding: .utf8)

let source = try! String(contentsOf: base.appendingPathComponent(binPath), encoding: .utf8)

/// Run tsc --watch, edit a file partway through, and collect what it printed. tsc never exits
/// in watch mode, so the run is cancelled once the second compile has been seen.
func watchRun(engine kind: String) async -> String {
    let good = "export const greeting: string = 'hello';\n"
    let broken = "export const greeting: number = 42;   // now the wrong type for two.ts\n"
    try? good.write(to: sources.appendingPathComponent("one.ts"), atomically: true, encoding: .utf8)
    // Remove any previous output so "did it recompile" is unambiguous.
    try? FileManager.default.removeItem(at: base.appendingPathComponent("out"))

    if kind == "ours" {
        let collected = Box("")
        let engine = NodeEngine(root: base, env: ["PATH": "/", "TERM": "dumb"])
        let task = Task.detached {
            let result = await engine.run(source: source, path: "/" + binPath,
                                          argv: ["node", "/" + binPath, "--watch", "--pretty", "false"],
                                          cwd: "/", stdin: "")
            collected.value = result.out + result.err
        }
        // Let the first compile land, then break the types and let the watch react.
        try? await Task.sleep(nanoseconds: 6_000_000_000)
        try? broken.write(to: sources.appendingPathComponent("one.ts"), atomically: true, encoding: .utf8)
        try? await Task.sleep(nanoseconds: 6_000_000_000)
        task.cancel()
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        return collected.value
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: realNode)
    process.arguments = [binPath, "--watch", "--pretty", "false"]
    process.currentDirectoryURL = base
    let out = Pipe()
    process.standardOutput = out
    process.standardError = Pipe()
    try? process.run()
    try? await Task.sleep(nanoseconds: 4_000_000_000)
    try? broken.write(to: sources.appendingPathComponent("one.ts"), atomically: true, encoding: .utf8)
    try? await Task.sleep(nanoseconds: 4_000_000_000)
    process.terminate()
    return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
}

final class Box: @unchecked Sendable {
    var value: String
    init(_ value: String) { self.value = value }
}

/// tsc's watch output carries timestamps and cursor control; compare the SHAPE — which
/// diagnostics appeared, in order — not the decoration.
func meaningful(_ text: String) -> [String] {
    var out: [String] = []
    for raw in text.components(separatedBy: "\n") {
        var line = raw
        // Strip escape sequences and the leading "HH:MM:SS - " stamp tsc prints per pass.
        while let start = line.firstIndex(of: "\u{1b}") {
            guard let end = line[start...].firstIndex(where: { $0.isLetter && $0 != "[" }) else { break }
            line.removeSubrange(start...end)
        }
        line = line.replacingOccurrences(of: #"^\d{1,2}:\d{2}:\d{2}\s*(AM|PM)?\s*-\s*"#,
                                         with: "", options: .regularExpression)
        line = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.isEmpty { continue }
        if line.contains("Starting compilation") || line.contains("File change detected") { out.append("[pass]") }
        else if line.contains("error TS") { out.append(String(line.drop(while: { $0 != "s" }).prefix(80))) }
        else if line.contains("Found ") { out.append(line) }
        else if line.contains("Watching for file changes") { out.append("[watching]") }
    }
    return out
}

let ours = await watchRun(engine: "ours")
let real = await watchRun(engine: "real")
let a = meaningful(ours), b = meaningful(real)

let compiledTwice = a.filter { $0 == "[pass]" }.count >= 2
let sawTheError = a.contains(where: { $0.contains("TS2322") || $0.contains("error TS") })
if a == b, compiledTwice, sawTheError {
    print("TSC --WATCH MATCH — the compiler watched, recompiled and reported the same diagnostics:")
    for line in a { print("  \(line)") }
} else {
    print(compiledTwice ? "" : "  (ours did not recompile after the edit)")
    print("MISMATCH")
    print("---- ours ----"); for line in a { print("  \(line)") }
    print("---- real ----"); for line in b { print("  \(line)") }
    print("---- ours raw (first 1200) ----\n\(String(ours.prefix(1200)))")
    exit(1)
}
try? FileManager.default.removeItem(at: base)
