import Foundation

// End-to-end: the prompt line through msh. `node tui.js` typed at the prompt must hand the
// terminal a NodeProgram (like less/top), raw-mode paints must land on the grid, and a
// mid-pipeline `node` must stay headless.

var failures = 0
func check(_ condition: Bool, _ label: String) {
    if condition { print("ok: \(label)") } else { failures += 1; print("FAIL: \(label)") }
}

@MainActor
func pump(until condition: () -> Bool, timeout: TimeInterval = 8, _ label: String) {
    let end = Date().addingTimeInterval(timeout)
    while !condition() && Date() < end {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
    check(condition(), label)
}

let root = FileManager.default.temporaryDirectory.appendingPathComponent("tty-e2e-\(UUID().uuidString)")
try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

try! """
process.stdin.setRawMode(true);
process.stdin.resume();
process.stdout.write('\\x1b[2J\\x1b[Hready ' + process.stdout.columns);
process.stdin.on('data', (d) => { if (String(d) === 'q') process.exit(0); });
""".write(to: root.appendingPathComponent("tui.js"), atomically: true, encoding: .utf8)

MainActor.assumeIsolated {
    let shell = MouseShell()
    var launched: TerminalProgram?
    var emitted: [String] = []
    let context = MouseShell.Context(
        root: root,
        emit: { emitted.append($0.text) },
        launchProgram: { launched = $0 }
    )

    // Interactive prompt line → the terminal gets a program, the command returns clean.
    var done = false
    Task { @MainActor in
        _ = await shell.runProgram("node tui.js", context: context, interactive: true)
        done = true
    }
    pump(until: { done }, "prompt line returns")
    check(launched is NodeProgram, "node tui.js handed the terminal a NodeProgram")
    check(launched?.title == "node tui.js", "program titled like the command")

    if let program = launched as? NodeProgram {
        let screen = TerminalScreen(rows: 8, columns: 40)
        let parser = AnsiParser(screen: screen)
        var exited = false
        program.start(io: TerminalProgramIO(
            rows: 8, columns: 40,
            write: { parser.feed($0) },
            exit: { exited = true }
        ))
        pump(until: { program.rendersScreen }, "raw mode takes the screen")
        pump(until: { screen.text(row: 0) == "ready 40" }, "grid shows the real geometry")
        program.input("q")
        pump(until: { exited }, "quit key ends the program")
    }

    // Mid-pipeline node stays headless: output is data, no program launch.
    launched = nil
    done = false
    var outputs: [MouseShell.Output] = []
    Task { @MainActor in
        outputs = await shell.runProgram("node -e 'console.log(\"deep\")' | tr a-z A-Z", context: context, interactive: true)
        done = true
    }
    pump(until: { done }, "pipeline returns")
    check(launched == nil, "mid-pipeline node stays headless")
    check(outputs.map(\.text) == ["DEEP"], "pipeline output flowed as data")
}

try? FileManager.default.removeItem(at: root)
print(failures == 0 ? "E2E ALL PASS" : "\(failures) FAILURES")
exit(failures == 0 ? 0 : 1)
