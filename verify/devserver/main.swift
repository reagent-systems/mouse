import Foundation
setvbuf(stdout, nil, _IONBF, 0)

// A dev server the way a user starts one: typed at the msh prompt, launched as a phase-T
// PROGRAM, streaming to the scrollback while it runs. Nothing had ever exercised that path with
// a program that does not exit — every previous node gate ran a program to completion.
//
// What has to hold: the shell hands the program off and returns the prompt immediately; its
// output reaches the transcript WHILE it runs, not at the end; the server actually answers on
// the LAN interface; and ^C ends it and frees the port, because nothing here tears a process
// down for us.

let base = FileManager.default.temporaryDirectory.appendingPathComponent("devserver-\(getpid())")
try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
try? """
    const http = require('http');
    let served = 0;
    const server = http.createServer((request, response) => {
      served += 1;
      console.log('request ' + served + ': ' + request.url);
      response.writeHead(200, { 'content-type': 'text/plain' });
      response.end('served ' + request.url);
    });
    server.listen(5393, '127.0.0.1', () => { console.log('listening on 5393'); });
    """.write(to: base.appendingPathComponent("server.js"), atomically: true, encoding: .utf8)

actor Transcript {
    private(set) var lines: [String] = []
    func add(_ line: String) { lines.append(line) }
    func clear() { lines.removeAll() }
    func snapshot() -> [String] { lines }
}
let transcript = Transcript()

@MainActor final class Host {
    var program: TerminalProgram?
    var exited = false
}
let host = await Host()

let outputs = await MainActor.run { () -> Task<[MouseShell.Output], Never> in
    Task { @MainActor in
        let shell = MouseShell()
        var context = MouseShell.Context(root: base)
        // The live scrollback: on the device this is what the terminal appends to while a
        // program runs, and it is the whole point of a dev server — vite prints its URL at
        // startup and you need to see it then, not when the server stops.
        context.emit = { output in Task { await transcript.add(output.text) } }
        context.launchProgram = { program in
            host.program = program
            program.start(io: TerminalProgramIO(rows: 24, columns: 80,
                write: { _ in },
                exit: { host.exited = true }))
        }
        return await shell.runProgram("node server.js", context: context, interactive: true)
    }
}

// The prompt has to come BACK — a launched program does not block the shell.
let returned = await outputs.value
let promptFreed = returned.allSatisfy { $0.text.isEmpty }
print("prompt returned immediately: \(promptFreed)")

try? await Task.sleep(nanoseconds: 1_200_000_000)
let launched = await MainActor.run { host.program != nil }
print("program launched: \(launched)")

var answered = "no answer"
do {
    let (data, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:5393/hello")!)
    answered = "\((response as? HTTPURLResponse)?.statusCode ?? 0) \(String(decoding: data, as: UTF8.self))"
} catch { answered = "request failed: \(error.localizedDescription)" }
print("while it runs: \(answered)")

try? await Task.sleep(nanoseconds: 400_000_000)
let mid = await transcript.snapshot()
print("streamed while running: \(mid.count) lines \(mid)")

// ^C, cooked mode: the program takes it as an interrupt and unwinds.
await MainActor.run { host.program?.input("\u{3}") }
try? await Task.sleep(nanoseconds: 1_200_000_000)
let finished = await MainActor.run { host.exited }
var stillUp = false
do { _ = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:5393/again")!); stillUp = true }
catch { stillUp = false }
print("after ^C: exited=\(finished) still listening=\(stillUp)")

// And now the one a user would actually type. vite installed by our own package manager, run
// from the prompt by name, serving a module to something that is not us.
print("installing vite…")
do { _ = try await PackageManager.install(requirements: ["vite": "^5.4.0"], into: base) }
catch { print("FAIL: install: \(error)"); exit(1) }
let app = base.appendingPathComponent("app/src")
try? FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
// The script a project actually ships, run the way its README says to run it.
try? #"""
{
  "name": "app", "private": true, "type": "module",
  "scripts": { "dev": "vite --port 5395 --host 127.0.0.1" }
}
"""#.write(to: base.appendingPathComponent("app/package.json"), atomically: true, encoding: .utf8)
try? "export const greeting: string = 'hello from a phone';\n"
    .write(to: app.appendingPathComponent("main.ts"), atomically: true, encoding: .utf8)

let viteTranscript = Transcript()
let viteHost = await Host()
let vitePrompt = await MainActor.run { () -> Task<[MouseShell.Output], Never> in
    Task { @MainActor in
        let shell = MouseShell()
        var context = MouseShell.Context(root: base)
        context.emit = { output in Task { await viteTranscript.add(output.text) } }
        context.clear = { Task { await viteTranscript.clear() } }
        context.launchProgram = { program in
            viteHost.program = program
            program.start(io: TerminalProgramIO(rows: 24, columns: 80, write: { _ in },
                                                exit: { viteHost.exited = true }))
        }
        return await shell.runProgram("cd app && npm run dev", context: context, interactive: true)
    }
}
_ = await vitePrompt.value
try? await Task.sleep(nanoseconds: 6_000_000_000)

var served = "no answer"
do {
    let (data, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:5395/src/main.ts")!)
    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
    let body = String(decoding: data, as: UTF8.self)
    served = "\(code) \(body.contains("hello from a phone") ? "transformed the module" : "unexpected body")"
} catch { served = "request failed: \(error.localizedDescription)" }
print("`npm run dev` from the prompt: \(served)")
let viteLines = await viteTranscript.snapshot()
print("vite said (\(viteLines.count) lines): \(viteLines.map { $0.debugDescription }.joined(separator: " "))")
await MainActor.run { viteHost.program?.input("\u{3}") }
try? await Task.sleep(nanoseconds: 1_500_000_000)

let plainWorked = answered.hasPrefix("200"), streamed = mid.count >= 2
let stopped = finished && !stillUp
// vite CLEARS before printing its banner, and what a user needs to see is the URL — first,
// not under two dozen blank rows left by the escapes that did the clearing.
let banner = viteLines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
let bannerIsFirst = viteLines.first.map { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? false
print("vite banner starts the transcript: \(bannerIsFirst), noise lines: \(viteLines.count - banner.count)")
if plainWorked, streamed, stopped, promptFreed, served.hasPrefix("200"), served.contains("transformed"),
   bannerIsFirst, banner.contains(where: { $0.contains("Local:") && $0.contains("5395") }) {
    print("DEV SERVER MATCH — a server started at the prompt streams while it runs, answers "
          + "requests from outside, and ends on ^C with its port released; vite does the same, "
          + "started by `npm run dev` from its own package.json, and its URL is the first "
          + "thing the transcript says")
} else {
    print("MISMATCH: dev server path")
    exit(1)
}
try? FileManager.default.removeItem(at: base)
