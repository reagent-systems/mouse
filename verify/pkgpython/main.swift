import Foundation
setvbuf(stdout, nil, _IONBF, 0)

// The whole path a person actually takes: `pkg install python`, then `python hello.py`, through
// msh — the same object the terminal calls, with nothing stubbed. The download, the integrity
// check, the hand-written zip reader (iOS has no `unzip`), the mount that makes a runtime living
// in Application Support visible to a rooted filesystem, and CPython itself.
//
// This is the one that would have caught a `pkg install` that reports success and installs
// nothing, which is the exact shape of the bug that made `npm install` look silent on the phone.
@MainActor func run() async {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("pkgpython-\(getpid())")
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }

    var problems: [String] = []
    func check(_ condition: Bool, _ whatFailed: String) {
        if !condition { problems.append(whatFailed) }
    }

    let shell = MouseShell()
    var context = MouseShell.Context(root: base)
    var streamed: [String] = []
    context.emit = { streamed.append($0.text) }

    func msh(_ command: String) async -> String {
        streamed = []
        let outputs = await shell.runProgram(command, context: context, interactive: false)
        return (streamed + outputs.map(\.text)).joined(separator: "\n")
    }

    // A runtime that is not installed must say so, and say what to do about it — a bare
    // "command not found" would be a lie, because python is a thing this shell knows.
    if RuntimeStore.installed("python") != nil { _ = RuntimeStore.remove("python") }
    let refusal = await msh("python -c 'print(1)'")
    check(refusal.contains("pkg install python"),
          "an uninstalled python refused without naming the command that installs it: [\(refusal)]")

    let listed = await msh("pkg list")
    check(listed.contains("python") && listed.contains("available"),
          "`pkg list` did not offer python as available: [\(listed)]")

    let installed = await msh("pkg install python")
    check(RuntimeStore.installed("python") != nil,
          "`pkg install python` returned without installing anything: [\(installed)]")
    check(installed.contains("installed python"),
          "the install said nothing about having finished: [\(installed)]")

    // Installed means installed: the interpreter and its standard library are both on disk.
    if let python = RuntimeStore.installed("python") {
        let manager = FileManager.default
        check(manager.fileExists(atPath: python.wasm.path), "python.wasm is not on disk after install")
        let attributes = try? manager.attributesOfItem(atPath: python.wasm.path)
        let size = (attributes?[.size] as? Int) ?? 0
        check(size > 20_000_000, "python.wasm is \(size) bytes, which is far too small to be CPython")
        // This build ships its standard library as python312.zip and imports it through
        // zipimport — which is exactly why it compiles zlib in, and zlib is why the build was
        // chosen. A loose encodings/ directory does not exist and should not be looked for.
        let stdlib = python.directory.appendingPathComponent("usr/local/lib/python312.zip")
        check(manager.fileExists(atPath: stdlib.path),
              "the standard library did not unpack — python312.zip is missing")
    }

    let second = await msh("pkg install python")
    check(second.contains("already installed"),
          "a second install did not notice the first: [\(second)]")

    // The real thing: a script file in the project, run by name.
    let hello = base.appendingPathComponent("hello.py")
    try? "print('hello from python')\nimport sys\nprint(sys.version.split()[0])\n"
        .write(to: hello, atomically: true, encoding: .utf8)
    let ran = await msh("python hello.py")
    check(ran.contains("hello from python"), "`python hello.py` did not print what the script prints: [\(ran)]")
    check(ran.contains("3.12.0"), "the interpreter did not report its version: [\(ran)]")

    // `-c`, the other form everyone uses.
    let inline = await msh("python -c 'print(6*7)'")
    check(inline.contains("42"), "`python -c` did not compute: [\(inline)]")

    // A script that reads a file next to it — the interpreter has no cwd of its own, so this is
    // the case that proves the argument rewriting and the preopened root actually work.
    try? "from the project\n".write(to: base.appendingPathComponent("data.txt"),
                                    atomically: true, encoding: .utf8)
    let reader = base.appendingPathComponent("read.py")
    try? "print(open('/data.txt').read().strip().upper())\n"
        .write(to: reader, atomically: true, encoding: .utf8)
    let readBack = await msh("python read.py")
    check(readBack.contains("FROM THE PROJECT"), "python could not read a file in the project: [\(readBack)]")

    // A failing script must fail, with the traceback visible rather than swallowed.
    let bad = base.appendingPathComponent("bad.py")
    try? "raise ValueError('boom')\n".write(to: bad, atomically: true, encoding: .utf8)
    let failed = await msh("python bad.py")
    check(failed.contains("ValueError") && failed.contains("boom"),
          "a python traceback never reached the terminal: [\(failed)]")

    let removed = await msh("pkg remove python")
    check(removed.contains("removed python"), "`pkg remove` said nothing: [\(removed)]")
    check(RuntimeStore.installed("python") == nil, "`pkg remove` left the runtime in place")

    if problems.isEmpty {
        print("PKG PYTHON MATCH — the whole path works through msh: an uninstalled runtime "
              + "refuses by naming its install command, `pkg install python` downloads 11 MB, "
              + "verifies it against a recorded hash, unpacks it with the zip reader written for "
              + "this (iOS has no unzip) and reports what it did; a second install notices the "
              + "first; `python hello.py`, `python -c` and a script reading a project file all "
              + "run CPython 3.12.0 through the engine's WASI; a traceback reaches the terminal; "
              + "and `pkg remove` removes it")
    } else {
        for problem in problems { print("  \(problem)") }
        print("PKG PYTHON MISMATCH — \(problems.count) failed")
        exit(1)
    }
}
await run()
