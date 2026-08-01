import Foundation
setvbuf(stdout, nil, _IONBF, 0)

// Python on this engine. The artifact is NOT in the repo — a language runtime is downloaded at
// install time here, never bundled — so the harness fetches it once into a cache and reuses it,
// the same way the package harnesses hit the real npm registry.
//
// This one does NOT diff against real node, and that is deliberate rather than convenient: real
// node segfaults on this module about as often as it runs it, flipping on differences as small
// as how deep the JS stack was when `wasi.start` was called (measured — `mini.js` at module
// scope survives, the same call one function deeper dies with SIGSEGV and no message). A
// reference that crashes half the time cannot grade anything. What IS asserted is CPython's own
// documented behaviour, which is a fact about Python rather than about either host: what the
// interpreter computes, what it writes, and what it exits with. Real node is still run, and what
// it managed is reported — as information, not as a gate.
let realNode = "/Users/thyfriendlyfox/.local/bin/node"
let release = "https://github.com/brettcannon/cpython-wasi-build/releases/download/v3.14.6/python-3.14.6-wasi_sdk-24.zip"

let cache = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".cache/mouse-verify/python-3.14.6")
let wasm = cache.appendingPathComponent("python.wasm")
let stdlib = cache.appendingPathComponent("lib")

if !FileManager.default.fileExists(atPath: wasm.path) {
    print("fetching CPython wasm32-wasi (14 MB) into \(cache.path)...")
    try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
    let zip = cache.appendingPathComponent("python.zip")
    let curl = Process()
    curl.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
    curl.arguments = ["-sSL", "-o", zip.path, release]
    try? curl.run()
    curl.waitUntilExit()
    let unzip = Process()
    unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
    unzip.arguments = ["-o", "-q", zip.path, "-d", cache.path]
    try? unzip.run()
    unzip.waitUntilExit()
    try? FileManager.default.removeItem(at: zip)
}

guard FileManager.default.fileExists(atPath: wasm.path) else {
    print("PYTHON MISMATCH — could not obtain python.wasm from \(release)")
    exit(1)
}

let here = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let corpus = here.appendingPathComponent("corpus.js")
let source = (try? String(contentsOf: corpus, encoding: .utf8)) ?? ""

var environment = ProcessInfo.processInfo.environment

// This engine's filesystem is ROOTED at the workspace: no script it runs can name a host path
// outside it. An installed runtime lives in Application Support, so it reaches programs through
// a mount — exactly the mechanism `pkg install python` uses on the phone, exercised here.
var ourEnvironment = environment
ourEnvironment["MOUSE_PYTHON_HOME"] = "/usr/lib/python/lib"
ourEnvironment["MOUSE_PYTHON_WASM"] = "/usr/lib/python/python.wasm"
environment["MOUSE_PYTHON_HOME"] = stdlib.path
environment["MOUSE_PYTHON_WASM"] = wasm.path

let engine = NodeEngine(root: here, env: ourEnvironment,
                        mounts: [(prefix: "/usr/lib/python", url: cache)])
let started = Date()
let mine = await engine.run(source: source, path: "/corpus.js",
                            argv: ["node", "/corpus.js"], cwd: "/", stdin: "")
let elapsed = Date().timeIntervalSince(started)

func rows(_ text: String) -> [String: String] {
    var out: [String: String] = [:]
    for line in text.split(separator: "\n") {
        let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        if parts.count == 2 { out[parts[0]] = parts[1] }
    }
    return out
}

let ours = rows(mine.out)

// CPython's own behaviour, not node's and not ours: 12² is 12, the squares below 1000 sum to
// 332833500, sys.exit(3) exits 3, and an uncaught ValueError exits 1 having already run what
// came before it.
let expected: [(name: String, value: String)] = [
    ("artifact-present", "true"),
    ("dash-c", "exit=0 said=\"hello from python\""),
    ("script-file", "exit=0 said=\"wasi 3.14.6\""),
    // sys.platform is "wasi" and the version is the release's own — both confirmed against the
    // real interpreter, so a wrong answer here means the module, not the expectation.
    ("stdlib-import", "exit=0 said=\"{\\\"root\\\": 12, \\\"wrapped\\\": [\\\"a b\\\", \\\"c\\\"]}\""),
    ("computes", "exit=0 said=\"332833500\""),
    ("exit-status", "exit=3 said=\"before\""),
    ("traceback-status", "exit=1 said=\"ran\""),
    ("file-round-trip", "exit=0 said=\"ROUND TRIP\""),
]

var differences: [String] = []
for want in expected {
    let got = ours[want.name] ?? "<scenario missing entirely>"
    if got != want.value {
        differences.append("  \(want.name)\n    want: \(want.value)\n    ours: \(got)")
    }
}

// What real node managed, for the record only.
let node = Process()
node.executableURL = URL(fileURLWithPath: realNode)
node.arguments = [corpus.path]
node.environment = environment
let out = Pipe(), err = Pipe()
node.standardOutput = out
node.standardError = err
try? node.run()
let theirText = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
_ = err.fileHandleForReading.readDataToEndOfFile()
node.waitUntilExit()
let theirRows = rows(theirText)
let theirNote = node.terminationStatus == 0
    ? "real node completed \(theirRows.count) of \(expected.count) rows"
    : "real node died with signal/status \(node.terminationStatus) after \(theirRows.count) rows"

if differences.isEmpty {
    print("PYTHON MATCH — CPython 3.14.6 runs on this engine: a 30 MB wasm32-wasi interpreter "
          + "instantiates and executes in \(Int(elapsed))s, `-c` and a script file both run, the "
          + "shipped stdlib imports through PYTHONHOME (json and math from the binary, textwrap "
          + "off disk), it computes the right answer, it reads and writes files in a preopened "
          + "directory, and sys.exit(3) and an uncaught exception arrive as exit 3 and exit 1. "
          + "(\(theirNote).)")
} else {
    for difference in differences { print(difference) }
    if !mine.err.isEmpty { print("our stderr: \(mine.err.prefix(800))") }
    print("(\(theirNote).)")
    print("PYTHON MISMATCH — \(differences.count) of \(expected.count) differ")
    exit(1)
}
