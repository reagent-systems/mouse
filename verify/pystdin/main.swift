import Foundation

// A WASI program on the terminal screen can READ what is typed — the engine's interactive
// stdin for wasm programs (the thing `hermes setup` needs). Checked end to end through the
// real TerminalSession: python sees a tty, prints a prompt with no newline, blocks in input(),
// the session delivers a line (cooked mode: echoed, Enter terminates), python prints it back.
// Needs the python runtime installed on this Mac (`pkg install python` through the app or a
// probe); without it the harness says so and fails — a missing runtime is not a pass.
setvbuf(stdout, nil, _IONBF, 0)
var failures = 0
func check(_ name: String, _ ok: Bool) { print("\(ok ? "ok  " : "FAIL") \(name)"); if !ok { failures += 1 } }

@MainActor
func run() async {
    guard RuntimeStore.installed("python") != nil else {
        print("FAIL python runtime not installed on this machine (pkg install python first)")
        failures += 1; return
    }
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pystdin-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let s = TerminalSession(root: root)
    _ = s.run("python -c \"import sys; print('tty', sys.stdin.isatty(), sys.stdout.isatty()); line = input('name: '); print('hello', line)\"")
    // Wait for the prompt to be ON SCREEN (no newline, so no transcript line yet).
    var waited = 0
    func lastRow() -> String {
        for r in stride(from: s.screen.rows - 1, through: 0, by: -1) {
            let t = s.screen.text(row: r).trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { return t }
        }
        return ""
    }
    while lastRow() != "name:" && (s.isRunning || s.program != nil) && waited < 3000 {
        try? await Task.sleep(for: .milliseconds(100)); waited += 1
    }
    check("python reached its prompt and blocked on stdin (\(waited/10)s)", lastRow() == "name:")
    _ = s.sendPaste("mouse"); _ = s.sendKey("\r")
    var settled = 0
    while (s.isRunning || s.program != nil), settled < 600 { try? await Task.sleep(for: .milliseconds(100)); settled += 1 }
    let text = s.screen.plainText + "\n" + s.lines.map(\.text).joined(separator: "\n")
    check("program exited after the line", !(s.isRunning || s.program != nil))
    check("stdin and stdout are a tty to the program", text.contains("tty True True"))
    check("the typed line was echoed after the prompt (cooked mode)", text.contains("name: mouse"))
    check("python read exactly the typed line", text.contains("hello mouse"))
    if failures > 0 { print("--- screen ---\n" + s.screen.plainText) }
}
await run()
print(failures == 0 ? "pystdin: all checks passed" : "pystdin: \(failures) failed")
exit(failures == 0 ? 0 : 1)
