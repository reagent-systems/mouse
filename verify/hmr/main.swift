import Foundation
setvbuf(stdout, nil, _IONBF, 0)

// Hot reload is the half of a dev server that makes it worth running, and it is a chain of
// four subsystems that have only ever been tested apart: kqueue fs.watch under chokidar, vite's
// module graph, an HTTP upgrade on our own socket server, and a WebSocket carrying the message.
// The peer here is the SYSTEM's WebSocket client, not ours — the browser's side of the wire,
// standing in for the browser.

let base = FileManager.default.temporaryDirectory.appendingPathComponent("hmr-\(getpid())")
let app = base.appendingPathComponent("app")
try? FileManager.default.createDirectory(at: app.appendingPathComponent("src"), withIntermediateDirectories: true)
print("installing vite…")
do { _ = try await PackageManager.install(requirements: ["vite": "^5.4.0"], into: base) }
catch { print("FAIL: install: \(error)"); exit(1) }

func put(_ text: String, _ path: String) {
    try? text.write(to: app.appendingPathComponent(path), atomically: true, encoding: .utf8)
}
put(#"{ "name": "app", "private": true, "type": "module" }"#, "package.json")
put("<!doctype html><script type=\"module\" src=\"/src/main.ts\"></script>\n", "index.html")
put("export const label: string = 'first';\n", "src/label.ts")
put("import { label } from './label.ts';\nif (import.meta.hot) { import.meta.hot.accept(); }\nconsole.log(label);\n", "src/main.ts")

@MainActor final class Host { var program: TerminalProgram?; var exited = false }
let host = await Host()
let prompt = await MainActor.run { () -> Task<[MouseShell.Output], Never> in
    Task { @MainActor in
        let shell = MouseShell()
        var context = MouseShell.Context(root: base)
        context.launchProgram = { program in
            host.program = program
            program.start(io: TerminalProgramIO(rows: 24, columns: 80, write: { _ in }, exit: { host.exited = true }))
        }
        return await shell.runProgram("cd app && npx vite --port 5397 --host 127.0.0.1", context: context, interactive: true)
    }
}
_ = await prompt.value
try? await Task.sleep(nanoseconds: 6_000_000_000)

// The module has to be SERVED before vite tracks it — HMR follows the graph it built.
var served = false
do {
    let (data, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:5397/src/main.ts")!)
    served = String(decoding: data, as: UTF8.self).contains("label")
} catch { served = false }
print("module served: \(served)")

// The browser's side: a real WebSocket, speaking vite's own subprotocol.
var request = URLRequest(url: URL(string: "ws://127.0.0.1:5397/")!)
request.setValue("vite-hmr", forHTTPHeaderField: "Sec-WebSocket-Protocol")
// Not `socket`: a top-level binding by that name shadows the POSIX socket() that the
// shell's own ICMP path calls, and the harness compiles the shell in.
let client = URLSession.shared.webSocketTask(with: request)
client.resume()

func nextMessage(timeout: TimeInterval) async -> String? {
    await withTaskGroup(of: String?.self) { group in
        group.addTask {
            guard let message = try? await client.receive() else { return nil }
            switch message {
            case .string(let text): return text
            case .data(let data): return String(decoding: data, as: UTF8.self)
            @unknown default: return nil
            }
        }
        group.addTask {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}

let hello = await nextMessage(timeout: 5)
print("handshake: \(hello ?? "nothing")")

// Now edit the file the way an editor would, and wait for the push.
try? await Task.sleep(nanoseconds: 600_000_000)
put("export const label: string = 'second';\n", "src/label.ts")

var pushed: String? = nil
for _ in 0..<4 {
    guard let message = await nextMessage(timeout: 4) else { break }
    if message.contains("update") || message.contains("full-reload") { pushed = message; break }
}
print("after the edit: \(pushed ?? "nothing arrived")")

client.cancel(with: .goingAway, reason: nil)
await MainActor.run { host.program?.input("\u{3}") }
try? await Task.sleep(nanoseconds: 1_200_000_000)

// vite names the ACCEPTING module in the update, not the file that changed — main.ts took
// the update on label.ts's behalf, which is what `import.meta.hot.accept()` means.
if served, let hello, hello.contains("connected"), let pushed,
   pushed.contains("js-update"), pushed.contains("/src/main.ts") {
    print("HMR MATCH — vite's watcher saw the edit and pushed it down a real WebSocket to a "
          + "client outside the app: \(pushed.prefix(90))")
} else {
    print("MISMATCH: hot reload chain")
    exit(1)
}
try? FileManager.default.removeItem(at: base)
