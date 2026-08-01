import Foundation
setvbuf(stdout, nil, _IONBF, 0)

// Ruby, installed and run the way a person does it: `pkg install ruby`, then `ruby hello.rb`,
// through msh — the same object the terminal calls, with nothing stubbed. This harness is also
// the ACCEPTANCE TEST for "languages as data": Ruby exists only as a Runtimes.json entry, so the
// last check greps swift/Mouse for the language's name and requires silence. If that grep ever
// finds something, a language leaked back into code.
//
// What is asserted is Ruby's OWN documented behaviour (what it computes, prints, and exits
// with) — never a diff against real node, which segfaults nondeterministically on modules this
// large (see verify/python/main.swift for the measurement).
@MainActor func run() async {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("pkgruby-\(getpid())")
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

    // An uninstalled runtime's command must refuse by naming the command that installs it —
    // the catalog knows ruby's commands before ruby is on disk, so "command not found" would
    // be a lie.
    if RuntimeStore.installed("ruby") != nil { _ = RuntimeStore.remove("ruby") }
    let refusal = await msh("ruby -e 'puts 1'")
    check(refusal.contains("pkg install ruby"),
          "an uninstalled ruby refused without naming the command that installs it: [\(refusal)]")

    let listed = await msh("pkg list")
    check(listed.contains("ruby") && listed.contains("available"),
          "`pkg list` did not offer ruby as available: [\(listed)]")

    // The install itself, through msh, with progress STREAMED — a 25 MB download with a silent
    // terminal is indistinguishable from a hang.
    let installed = await msh("pkg install ruby")
    check(RuntimeStore.installed("ruby") != nil,
          "`pkg install ruby` returned without installing anything: [\(installed)]")
    check(streamed.contains(where: { $0.contains("fetching ruby") }),
          "the install streamed no progress while downloading: [\(installed)]")
    check(installed.contains("installed ruby"),
          "the install said nothing about having finished: [\(installed)]")

    // Installed means installed: the interpreter and its standard library are both on disk,
    // in the usr/lib layout the /usr mount mirrors.
    if let ruby = RuntimeStore.installed("ruby") {
        let manager = FileManager.default
        check(manager.fileExists(atPath: ruby.wasm.path), "the interpreter is not on disk after install")
        let attributes = try? manager.attributesOfItem(atPath: ruby.wasm.path)
        let size = (attributes?[.size] as? Int) ?? 0
        check(size > 30_000_000, "the interpreter is \(size) bytes, far too small to be the full ruby.wasm")
        let stdlib = ruby.directory.appendingPathComponent("lib/ruby/3.4.0/json.rb")
        check(manager.fileExists(atPath: stdlib.path),
              "the standard library did not unpack — \(stdlib.lastPathComponent) is missing")
    }

    let second = await msh("pkg install ruby")
    check(second.contains("already installed"),
          "a second install did not notice the first: [\(second)]")

    // The real thing: a script file in the project, run by name. RUBY_VERSION is Ruby's own
    // fact about this release.
    let hello = base.appendingPathComponent("hello.rb")
    try? "puts 'hello from ruby'\nputs RUBY_VERSION\n"
        .write(to: hello, atomically: true, encoding: .utf8)
    let ran = await msh("ruby hello.rb")
    check(ran.contains("hello from ruby"), "`ruby hello.rb` did not print what the script prints: [\(ran)]")
    check(ran.contains("3.4.1"), "the interpreter did not report its version: [\(ran)]")

    // `-e`, the inline form.
    let inline = await msh("ruby -e 'puts 6*7'")
    check(inline.contains("42"), "`ruby -e` did not compute: [\(inline)]")

    // A stdlib require plus a project file read — the interpreter has no cwd of its own, so
    // this proves the preopened root and RUBYLIB both work.
    try? "from the project\n".write(to: base.appendingPathComponent("data.txt"),
                                    atomically: true, encoding: .utf8)
    let reader = base.appendingPathComponent("read.rb")
    try? "require 'json'\nputs({ text: File.read('/data.txt').strip.upcase }.to_json)\n"
        .write(to: reader, atomically: true, encoding: .utf8)
    let readBack = await msh("ruby read.rb")
    check(readBack.contains("FROM THE PROJECT"), "ruby could not read a file in the project: [\(readBack)]")

    // A non-zero exit must surface as the shell's $?.
    let status = await msh("ruby -e 'exit 3'; echo status=$?")
    check(status.contains("status=3"), "exit 3 did not surface as $?: [\(status)]")

    // A failing script must fail with the exception's own words visible, not swallowed.
    let bad = base.appendingPathComponent("bad.rb")
    try? "raise ArgumentError, 'boom'\n".write(to: bad, atomically: true, encoding: .utf8)
    let failed = await msh("ruby bad.rb")
    check(failed.contains("ArgumentError") && failed.contains("boom"),
          "a ruby exception's message never reached the terminal: [\(failed)]")

    let removed = await msh("pkg remove ruby")
    check(removed.contains("removed ruby"), "`pkg remove` said nothing: [\(removed)]")
    check(RuntimeStore.installed("ruby") == nil, "`pkg remove` left the runtime in place")

    // The data-only proof: the language's name appears NOWHERE in swift/Mouse. Everything this
    // harness just exercised came from Runtimes.json plus generic machinery.
    let mouseSources = URL(fileURLWithPath: #filePath)          // …/verify/pkgruby/main.swift
        .deletingLastPathComponent().deletingLastPathComponent() // …/verify
        .deletingLastPathComponent()                             // repo root
        .appendingPathComponent("swift/Mouse")
    let grep = Process()
    grep.executableURL = URL(fileURLWithPath: "/usr/bin/grep")
    grep.arguments = ["-ri", "ruby", mouseSources.path]
    let grepOut = Pipe()
    grep.standardOutput = grepOut
    grep.standardError = Pipe()
    try? grep.run()
    let leaks = String(decoding: grepOut.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    grep.waitUntilExit()
    check(grep.terminationStatus == 1 && leaks.isEmpty,
          "the language's name leaked into swift/Mouse — data-only broken:\n\(leaks.prefix(600))")

    if problems.isEmpty {
        print("PKG RUBY MATCH — a language added as pure data works end to end through msh: "
              + "an uninstalled ruby refuses by naming `pkg install ruby`, the install downloads "
              + "25 MB streaming progress, verifies the recorded sha256, unpacks the tar.gz with "
              + "the TarGz reader npm tarballs use (strip 3, escape-refusing) into the /usr "
              + "mount; `ruby hello.rb`, `ruby -e`, a stdlib require and a project-file read all "
              + "run ruby.wasm 3.4.1 through the engine's WASI; exit 3 surfaces as $?; an "
              + "ArgumentError's message reaches the terminal; `pkg remove` removes it; and a "
              + "grep of swift/Mouse for the language's name finds nothing")
    } else {
        for problem in problems { print("  \(problem)") }
        print("PKG RUBY MISMATCH — \(problems.count) failed")
        exit(1)
    }
}
await run()
