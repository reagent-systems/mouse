import Foundation
setvbuf(stdout, nil, _IONBF, 0)

// `npm run dev` is the first line of every README, and msh had install and ls and nothing else.
// Real npm is the peer: the same package.json, the same scripts, the same arguments — what the
// script PRINTS and the status it exits with have to match, including the pre/post hooks and
// the environment npm hands a script.

let realNpm = "/Users/thyfriendlyfox/.local/bin/npm"
let base = FileManager.default.temporaryDirectory.appendingPathComponent("npmrun-\(getpid())")
let ours = base.appendingPathComponent("ours"), real = base.appendingPathComponent("real")
for dir in [ours, real] {
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try? """
        {
          "name": "runner", "version": "2.3.0", "private": true,
          "scripts": {
            "greet": "node -e \\"console.log('hello ' + (process.argv[2] || 'world'))\\"",
            "env": "node -e \\"console.log(process.env.npm_lifecycle_event, process.env.npm_package_name, process.env.npm_package_version)\\"",
            "prebuild": "node -e \\"console.log('before')\\"",
            "build": "node -e \\"console.log('building')\\"",
            "postbuild": "node -e \\"console.log('after')\\"",
            "chain": "node -e \\"console.log('one')\\" && node -e \\"console.log('two')\\"",
            "fails": "node -e \\"process.exit(3)\\"",
            "test": "node -e \\"console.log('tests pass')\\""
          }
        }
        """.write(to: dir.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
}

@MainActor func msh(_ line: String) async -> (out: String, status: Int32) {
    let shell = MouseShell()
    let context = MouseShell.Context(root: ours)
    let outputs = await shell.runProgram(line, context: context, interactive: false)
    let text = outputs.map(\.text).joined(separator: "\n")
    return (text.trimmingCharacters(in: .whitespacesAndNewlines), shell.lastStatus)
}

func npm(_ args: [String]) -> (out: String, status: Int32) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: realNpm)
    // --silent FIRST: after the script's own `--` it would be passed to the script instead.
    process.arguments = ["--silent"] + args
    process.currentDirectoryURL = real
    let out = Pipe()
    process.standardOutput = out
    process.standardError = Pipe()
    try? process.run()
    let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    return (text.trimmingCharacters(in: .whitespacesAndNewlines), process.terminationStatus)
}

let cases: [(String, [String])] = [
    ("npm run greet", ["run", "greet"]),
    ("npm run greet -- mouse", ["run", "greet", "--", "mouse"]),
    ("npm run env", ["run", "env"]),
    ("npm run build", ["run", "build"]),
    ("npm run chain", ["run", "chain"]),
    ("npm run fails", ["run", "fails"]),
    ("npm test", ["test"]),
    ("npm run nope", ["run", "nope"]),
]

var failures = 0
for (line, args) in cases {
    let mine = await msh(line)
    let theirs = npm(args)
    // A missing script: both must refuse and both must be non-zero; the wording is npm's own.
    let sameEnough = line.hasSuffix("nope")
        ? (mine.status != 0 && theirs.status != 0 && mine.out.contains("Missing script"))
        : (mine.out == theirs.out && mine.status == theirs.status)
    if sameEnough {
        print("ok: \(line) -> \(mine.out.replacingOccurrences(of: "\n", with: " | ")) [\(mine.status)]")
    } else {
        failures += 1
        print("MISMATCH: \(line)\n  ours: \(mine.out.debugDescription) [\(mine.status)]\n  npm:  \(theirs.out.debugDescription) [\(theirs.status)]")
    }
}

// And bare `npm run`, which lists.
let listed = await msh("npm run")
let listsAll = ["greet", "build", "chain", "test"].allSatisfy { listed.out.contains($0) }
print("bare `npm run` lists the scripts: \(listsAll)")

if failures == 0, listsAll {
    print("NPM RUN MATCH — all \(cases.count) behave as real npm does, pre/post hooks, argument "
          + "passing and exit status included")
} else {
    print("FAIL: \(failures) of \(cases.count) differ")
    exit(1)
}
try? FileManager.default.removeItem(at: base)
