import Foundation

// Headless verification of the TTY join: NodeProgram (phase G engine) driving the phase-T
// screen, per AGENTS.md — TerminalProgramIO.write wired into an AnsiParser, grid asserted
// after keystrokes.

var failures = 0
func check(_ condition: Bool, _ label: String) {
    if condition { print("ok: \(label)") } else { failures += 1; print("FAIL: \(label)") }
}
func checkEqual(_ got: String, _ want: String, _ label: String) {
    if got == want { print("ok: \(label)") } else {
        failures += 1
        print("FAIL: \(label)\n  got:  \(got)\n  want: \(want)")
    }
}

@MainActor
func pump(seconds: TimeInterval) {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
}

@MainActor
func pump(until condition: () -> Bool, timeout: TimeInterval = 8, _ label: String) {
    let end = Date().addingTimeInterval(timeout)
    while !condition() && Date() < end {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
    check(condition(), label)
}

@MainActor
final class Host {
    let screen: TerminalScreen
    let parser: AnsiParser
    var transcript: [(String, Bool)] = []
    var exited = false
    let program: NodeProgram
    let rows: Int
    let columns: Int

    init(source: String, root: URL, rows: Int = 24, columns: Int = 80) {
        self.rows = rows
        self.columns = columns
        screen = TerminalScreen(rows: rows, columns: columns)
        parser = AnsiParser(screen: screen)
        let engine = NodeEngine(root: root, env: ["TERM": "xterm-256color"])
        var collect: ((String, Bool) -> Void)!
        var recorded: [(String, Bool)] = []
        collect = { line, isError in recorded.append((line, isError)) }
        program = NodeProgram(title: "node test.js", source: source, path: "/test.js",
                              argv: ["node", "/test.js"], cwd: "/", engine: engine,
                              transcript: { line, isError in collect(line, isError) },
                              onExit: {})
        collect = { [weak self] line, isError in self?.transcript.append((line, isError)) }
        transcript = recorded
    }

    func start() {
        // Mirror TerminalSession.launch: query replies flow back to the program's stdin.
        parser.respond = { [weak self] reply in self?.program.input(reply) }
        program.start(io: TerminalProgramIO(
            rows: rows,
            columns: columns,
            write: { [weak self] text in self?.parser.feed(text) },
            exit: { [weak self] in self?.exited = true }
        ))
    }

    var lines: [String] { transcript.map(\.0) }

    /// Mirror TerminalSession.sendPaste: bracket the text when the program enabled 2004.
    func paste(_ text: String) {
        if screen.bracketedPaste { program.input("\u{1b}[200~" + text + "\u{1b}[201~") }
        else { program.input(text) }
    }
}

let root = FileManager.default.temporaryDirectory.appendingPathComponent("tty-verify-\(UUID().uuidString)")
try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }

@MainActor
func runTests() {
    // -- 1: transcript mode — lines stream to the scrollback, isTTY and size are real ------
    do {
        let host = Host(source: """
        console.log('cols=' + process.stdout.columns + ' rows=' + process.stdout.rows + ' tty=' + process.stdout.isTTY);
        console.log('isatty=' + require('tty').isatty(1));
        console.error('to-stderr');
        """, root: root, rows: 20, columns: 60)
        host.start()
        pump(until: { host.exited }, "1: plain script exits")
        checkEqual(host.lines.joined(separator: "|"), "cols=60 rows=20 tty=true|isatty=true|to-stderr", "1: transcript lines")
        check(host.transcript.last?.1 == true, "1: stderr line marked as error")
        check(host.program.rendersScreen == false, "1: printing stays in transcript mode")
    }

    // -- 2: stdin listeners keep the program alive; keys arrive as data ---------------------
    do {
        let host = Host(source: """
        process.stdin.on('data', (d) => {
          const s = String(d);
          process.stdout.write('[' + s + ']');
          if (s === 'q') process.exit(7);
        });
        """, root: root)
        host.start()
        pump(seconds: 0.5)
        check(!host.exited, "2: waiting on stdin does not exit")
        host.program.input("a")
        pump(seconds: 0.2)
        host.program.input("q")
        pump(until: { host.exited }, "2: exits on quit key")
        checkEqual(host.lines.joined(), "[a][q]", "2: keystrokes echoed through stdout")
    }

    // -- 3: raw mode takes the grid; keystrokes redraw it; raw ^C is a byte -----------------
    do {
        let host = Host(source: """
        process.stdin.setRawMode(true);
        process.stdin.resume();
        process.stdout.write('\\x1b[2J\\x1b[H> ');
        process.stdin.on('data', (d) => {
          const s = String(d);
          if (s === '\\u0003') { process.stdout.write('\\x1b[2;1Hbye'); process.exit(0); }
          process.stdout.write(s.toUpperCase());
        });
        """, root: root, rows: 6, columns: 20)
        host.start()
        pump(until: { host.program.rendersScreen }, "3: raw mode flips to screen mode")
        pump(seconds: 0.2)
        checkEqual(host.screen.text(row: 0), ">", "3: prompt painted on grid (trailing blank trimmed)")
        host.program.input("h")
        host.program.input("i")
        pump(seconds: 0.3)
        checkEqual(host.screen.text(row: 0), "> HI", "3: keystrokes drawn after redraw")
        host.program.input("\u{3}")
        pump(until: { host.exited }, "3: raw ^C delivered as byte, program exits itself")
        checkEqual(host.screen.text(row: 1), "bye", "3: program drew its goodbye")
    }

    // -- 4: cooked ^C with no handler ends the program ---------------------------------------
    do {
        let host = Host(source: "process.stdin.on('data', () => {});", root: root)
        host.start()
        pump(seconds: 0.4)
        check(!host.exited, "4: idle listener stays alive")
        host.program.input("\u{3}")
        pump(until: { host.exited }, "4: cooked ^C without handler kills the program")
    }

    // -- 5: cooked ^C runs the program's SIGINT handler --------------------------------------
    do {
        let host = Host(source: """
        process.on('SIGINT', () => { console.log('caught'); process.exit(3); });
        process.stdin.on('data', () => {});
        """, root: root)
        host.start()
        pump(seconds: 0.3)
        host.program.input("\u{3}")
        pump(until: { host.exited }, "5: handler decides the exit")
        checkEqual(host.lines.joined(), "caught", "5: SIGINT handler ran")
    }

    // -- 6: rotation is a real resize event --------------------------------------------------
    do {
        let host = Host(source: """
        process.stdout.on('resize', () => { console.log('now ' + process.stdout.columns + 'x' + process.stdout.rows); });
        process.stdin.on('data', () => {});
        """, root: root)
        host.start()
        pump(seconds: 0.3)
        host.program.resize(rows: 30, columns: 100)
        pump(seconds: 0.3)
        checkEqual(host.lines.joined(), "now 100x30", "6: resize event with new geometry")
        host.program.input("\u{3}")
        pump(until: { host.exited }, "6: cleanup")
    }

    // -- 7: alt screen flips to the grid, exit restores the main screen ----------------------
    do {
        let host = Host(source: """
        process.stdout.write('\\x1b[?1049h\\x1b[Hfull-screen');
        setTimeout(() => process.exit(0), 150);
        """, root: root, rows: 6, columns: 20)
        host.start()
        pump(until: { host.program.rendersScreen }, "7: alt screen flips to screen mode")
        checkEqual(host.screen.text(row: 0), "full-screen", "7: paint landed on the grid")
        pump(until: { host.exited }, "7: exits")
        check(!host.screen.isAlternate, "7: main screen restored on exit")
    }

    // -- 8: transcript lines arrive with escapes stripped ------------------------------------
    do {
        let host = Host(source: #"console.log('\x1b[31mred\x1b[0m plain\r');"#, root: root)
        host.start()
        pump(until: { host.exited }, "8: exits")
        checkEqual(host.lines.joined(), "red plain", "8: SGR and CR stripped for the scrollback")
    }

    // -- 10: readline question — echo, backspace editing, answer delivery --------------------
    do {
        let host = Host(source: """
        const readline = require('readline');
        const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
        rl.question('name? ', (answer) => {
          process.stdout.write('\\r\\nhello ' + answer);
          rl.close();
          process.exit(0);
        });
        """, root: root, rows: 6, columns: 30)
        host.start()
        pump(until: { host.program.rendersScreen }, "10: readline takes the terminal (raw mode)")
        pump(seconds: 0.2)
        checkEqual(host.screen.text(row: 0), "name?", "10: question painted")
        for key in ["b", "o", "b", "x"] { host.program.input(key) }
        pump(seconds: 0.2)
        host.program.input("\u{7f}")
        pump(seconds: 0.2)
        checkEqual(host.screen.text(row: 0), "name? bob", "10: echo + backspace editing")
        host.program.input("\r")
        pump(until: { host.exited }, "10: enter delivers the answer")
        checkEqual(host.screen.text(row: 2), "hello bob", "10: answer reached the program")
    }

    // -- 11: readline/promises — awaited question; ^C without SIGINT listener kills ----------
    do {
        let host = Host(source: """
        const readline = require('readline/promises');
        const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
        rl.question('pick: ').then((answer) => { process.stdout.write('\\r\\ngot ' + answer); process.exit(0); });
        """, root: root, rows: 6, columns: 30)
        host.start()
        pump(until: { host.program.rendersScreen }, "11: promises interface runs")
        host.program.input("7")
        host.program.input("\r")
        pump(until: { host.exited }, "11: awaited answer resolves")
        checkEqual(host.screen.text(row: 2), "got 7", "11: promise carried the line")
    }

    do {
        let host = Host(source: """
        const readline = require('readline');
        const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
        rl.question('q: ', () => {});
        """, root: root)
        host.start()
        pump(seconds: 0.4)
        check(!host.exited, "12: question waits")
        host.program.input("\u{3}")
        pump(until: { host.exited }, "12: ^C with no SIGINT listener ends a readline program")
    }

    // -- 13: prompts, a real npm package — interactive text input end-to-end -----------------
    do {
        var installed = false
        Task { @MainActor in
            _ = try? await PackageManager.install(requirements: ["prompts": "latest"], into: root)
            installed = true
        }
        pump(until: { installed }, timeout: 120, "13: prompts installed")
        let host = Host(source: """
        const prompts = require('prompts');
        (async () => {
          const response = await prompts({ type: 'text', name: 'who', message: 'name?' });
          process.stdout.write('\\r\\nANSWER=' + response.who);
          process.exit(0);
        })();
        """, root: root, rows: 8, columns: 40)
        host.start()
        pump(until: { host.program.rendersScreen }, "13: prompts takes the screen (raw keys)")
        pump(seconds: 0.4)
        for key in ["b", "o", "b"] { host.program.input(key) }
        pump(seconds: 0.3)
        host.program.input("\r")
        pump(until: { host.exited }, timeout: 12, "13: prompts completes")
        let grid = (0..<8).map { host.screen.text(row: $0) }.joined(separator: "\n")
        check(grid.contains("ANSWER=bob"), "13: typed answer flowed through the real package")
    }

    // -- 14: ink — a real React TUI framework draws on the grid and takes keystrokes ---------
    do {
        var installed = false
        Task { @MainActor in
            _ = try? await PackageManager.install(requirements: ["ink": "latest", "react": "^19"], into: root)
            installed = true
        }
        pump(until: { installed }, timeout: 300, "14: ink + react installed")
        let host = Host(source: """
        import React from 'react';
        import { render, Text, useInput, useApp } from 'ink';
        const App = () => {
          const { exit } = useApp();
          const [key, setKey] = React.useState('none');
          useInput((input) => { if (input === 'q') exit(); else setKey(input); });
          return React.createElement(Text, null, 'key=' + key);
        };
        render(React.createElement(App));
        """, root: root, rows: 8, columns: 40)
        host.start()
        pump(until: { host.program.rendersScreen }, timeout: 20, "14: ink takes the screen")
        // The first frame precedes the raw-mode flip, so it lands in the scrollback — the
        // mode model working as designed; the app lives on the grid from the next render.
        pump(until: { host.lines.contains { $0.contains("key=none") } }, timeout: 10,
             "14: first frame reached the transcript")
        host.program.input("x")
        pump(until: { (0..<8).contains { host.screen.text(row: $0).contains("key=x") } }, timeout: 10,
             "14: keypress re-rendered through React onto the grid")
        host.program.input("q")
        pump(until: { host.exited }, timeout: 15, "14: useApp exit ends the program")
    }

    // -- 18: THE VERTICAL SLICE — SDK streams → ink renders → the phase-T grid --------------
    // Every layer at once, the way the product actually works: the Anthropic SDK streams
    // server-sent events through our Response.body, an ink component appends each delta to
    // React state, ink repaints, and the text lands on the terminal grid through the
    // NodeProgram/ANSI path. No individual test covers this seam.
    do {
        var installed = false
        Task { @MainActor in
            _ = try? await PackageManager.install(
                requirements: ["ink": "latest", "react": "^19", "@anthropic-ai/sdk": "latest"], into: root)
            installed = true
        }
        pump(until: { installed }, timeout: 300, "18: ink + react + sdk installed")
        let host = Host(source: """
        import React from 'react';
        import { render, Text, Box, useInput } from 'ink';
        import Anthropic from '@anthropic-ai/sdk';

        const sse = [
          'event: message_start',
          'data: {"type":"message_start","message":{"id":"m","type":"message","role":"assistant","model":"claude-sonnet-4-5","content":[],"stop_reason":null,"usage":{"input_tokens":2,"output_tokens":0}}}',
          '',
          'event: content_block_start',
          'data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}',
          '',
          'event: content_block_delta',
          'data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"HELLO "}}',
          '',
          'event: content_block_delta',
          'data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"FROM MOUSE"}}',
          '',
          'event: content_block_stop',
          'data: {"type":"content_block_stop","index":0}',
          '',
          'event: message_delta',
          'data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":4}}',
          '',
          'event: message_stop',
          'data: {"type":"message_stop"}',
          '',
        ].join('\\n');
        // The fake endpoint must exist BEFORE the client is built: the SDK captures fetch.
        globalThis.fetch = () => Promise.resolve(new Response(sse, {
          status: 200, headers: { 'content-type': 'text/event-stream' },
        }));
        const client = new Anthropic({ apiKey: 'sk-fake' });

        const App = () => {
          const [text, setText] = React.useState('');
          const [done, setDone] = React.useState(false);
          // A real agent CLI has an input box, which is what makes ink take raw mode and
          // draw on the SCREEN rather than streaming lines into the scrollback.
          useInput(() => {});
          React.useEffect(() => {
            (async () => {
              const stream = await client.messages.create({
                model: 'claude-sonnet-4-5', max_tokens: 32, stream: true,
                messages: [{ role: 'user', content: 'hi' }],
              });
              for await (const event of stream) {
                if (event.type === 'content_block_delta' && event.delta.type === 'text_delta') {
                  setText((prev) => prev + event.delta.text);
                }
              }
              setDone(true);
            })();
          }, []);
          return React.createElement(Box, { borderStyle: 'round' },
            React.createElement(Text, null, (done ? 'done: ' : 'streaming: ') + text));
        };
        render(React.createElement(App));
        setTimeout(() => process.exit(0), 4000);
        """, root: root, rows: 10, columns: 60)
        host.start()
        pump(until: { host.program.rendersScreen }, timeout: 30, "18: ink takes the screen")
        // The assembled streamed text must appear ON THE GRID (or in the pre-raw scrollback).
        func showsStreamedText() -> Bool {
            let grid = (0..<10).map { host.screen.text(row: $0) }.joined(separator: "\n")
            return grid.contains("HELLO FROM MOUSE") || host.lines.contains { $0.contains("HELLO FROM MOUSE") }
        }
        pump(until: { showsStreamedText() }, timeout: 30,
             "18: streamed model tokens rendered by ink onto the phase-T screen")
        func showsDone() -> Bool {
            let grid = (0..<10).map { host.screen.text(row: $0) }.joined(separator: "\n")
            return grid.contains("done:") || host.lines.contains { $0.contains("done:") }
        }
        pump(until: { showsDone() }, timeout: 20, "18: stream completion re-rendered")
        pump(until: { host.exited }, timeout: 20, "18: program exits cleanly")
    }

    // -- 17: bracketed paste — a multi-line paste arrives as ONE block, not a burst of Enters
    do {
        let host = Host(source: """
        process.stdin.setRawMode(true);
        process.stdin.resume();
        let buf = '';
        let submits = 0;
        process.stdin.on('data', (d) => {
          buf += String(d);
          // A naive prompt submits on every newline; a bracketed-paste-aware one holds the
          // block until ESC[201~. Count how the paste is delivered.
          if (buf.includes('\\u001b[201~')) {
            const inner = buf.slice(buf.indexOf('\\u001b[200~') + 6, buf.indexOf('\\u001b[201~'));
            process.stdout.write('PASTED_LINES=' + inner.split('\\n').length + ' MARKERS=1');
            process.exit(0);
          }
        });
        process.stdout.write('\\u001b[?2004h');   // enable bracketed paste
        """, root: root, rows: 8, columns: 40)
        host.start()
        pump(until: { host.program.rendersScreen }, "17: paste program takes the screen")
        pump(until: { host.screen.bracketedPaste }, "17: program enabled bracketed paste")
        host.paste("line one\nline two\nline three")   // a 3-line paste
        pump(until: { host.exited }, timeout: 8, "17: program received the whole paste and exited")
        let out = (0..<8).map { host.screen.text(row: $0) }.joined()
        check(out.contains("PASTED_LINES=3") && out.contains("MARKERS=1"),
              "17: multi-line paste delivered as one bracketed block")
    }

    // -- 16: terminal query→response round trip (DSR/DA/DECRQM) through real stdin ----------
    do {
        // A program that PROBES the terminal and blocks on the reply. Without the response
        // path it would hang; with it, the answer arrives on stdin and it proceeds.
        let host = Host(source: """
        process.stdin.setRawMode(true);
        process.stdin.resume();
        let buf = '';
        process.stdin.on('data', (d) => {
          buf += String(d);
          // Collect three replies: DSR cursor pos (…R), primary DA (…c), DECRQM (…$y).
          if (buf.includes('R') && buf.includes('c') && buf.includes('y')) {
            const seen = buf.replace(/\\u001b/g, 'ESC');
            process.exit(seen.includes('ESC[1;6R') && seen.includes('ESC[?6c') && seen.includes('ESC[?2026;2$y') ? 0 : 1);
          }
        });
        process.stdout.write('\\u001b[1;6H');      // park cursor at row 1, col 6
        process.stdout.write('\\u001b[6n');         // DSR: where is the cursor?
        process.stdout.write('\\u001b[c');          // DA: what are you?
        process.stdout.write('\\u001b[?2026$p');    // DECRQM: is synchronized output set?
        """, root: root, rows: 10, columns: 40)
        host.start()
        pump(until: { host.program.rendersScreen }, "16: query program takes the screen")
        pump(until: { host.exited }, timeout: 8, "16: program received all three replies and exited")
        check(host.exited, "16: DSR/DA/DECRQM round-tripped through stdin (no hang)")
    }

    // -- 15: a REAL claude-code ink frame renders aligned via ONLCR, vs pyte ----------------
    do {
        // Captured bytes from claude-code 1.0.128's config-recovery UI: a bordered box whose
        // lines end in bare `\n`. Without ONLCR the frame shears diagonally (LF is index).
        let frameURL = URL(fileURLWithPath: "cc-frame.bin")
        let refURL = URL(fileURLWithPath: "cc-frame.pyte")
        if let raw = try? Data(contentsOf: frameURL), let ref = try? String(contentsOf: refURL, encoding: .utf8) {
            let frame = String(decoding: raw, as: UTF8.self)
            let screen = TerminalScreen(rows: 30, columns: 80)
            let parser = AnsiParser(screen: screen)
            parser.feed(NodeProgram.onlcr(frame))   // the fix under test
            let refLines = ref.components(separatedBy: "\n")
            var mismatches = 0
            for row in 0..<30 {
                let got = screen.text(row: row)
                let want = row < refLines.count ? refLines[row] : ""
                if got.trimmingCharacters(in: .whitespaces) != want.trimmingCharacters(in: .whitespaces) { mismatches += 1 }
            }
            check(mismatches == 0, "15: real ink frame renders byte-for-byte vs pyte (ONLCR applied)")
            check(screen.text(row: 0).hasPrefix("╭─"), "15: box top border at column 0")
            check(screen.text(row: 2).contains("│ Configuration Error"), "15: content aligned inside the box")
            // And prove the shear is real: WITHOUT onlcr the same frame must NOT align.
            let bad = TerminalScreen(rows: 30, columns: 80)
            AnsiParser(screen: bad).feed(frame)
            check(!bad.text(row: 2).contains("│ Configuration Error"), "15: without ONLCR the frame shears (control)")
        } else {
            check(false, "15: could not load cc-frame fixtures")
        }
    }

    // -- 9: partial lines flush on exit; interleaved stderr keeps its color ------------------
    do {
        let host = Host(source: """
        process.stdout.write('no-newline');
        process.stderr.write('err-line\\n');
        """, root: root)
        host.start()
        pump(until: { host.exited }, "9: exits")
        let flat = host.transcript.map { "\($0.1 ? "E" : "O"):\($0.0)" }.sorted().joined(separator: "|")
        checkEqual(flat, "E:err-line|O:no-newline", "9: both streams land, partial line flushed")
    }
}

MainActor.assumeIsolated {
    runTests()
}

print(failures == 0 ? "ALL PASS" : "\(failures) FAILURES")
exit(failures == 0 ? 0 : 1)
