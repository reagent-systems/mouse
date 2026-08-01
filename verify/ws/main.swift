import Foundation

// Real-package proof for the 'upgrade' path: the genuine `ws` package, installed by OUR
// package manager. A WebSocket is HTTP's upgrade handshake (sha1 of the client key, base64)
// followed by a framed binary protocol on the raw socket — so this exercises http's upgrade
// event, crypto, and net's byte handling at once, in both directions:
//   1. our ws SERVER talked to by a REAL node ws client
//   2. our ws CLIENT talking to a REAL node ws server
// Both compared against the same peer talking to real node.

setvbuf(stdout, nil, _IONBF, 0)   // a watchdog kill must not swallow progress
let realNode = "/Users/thyfriendlyfox/.local/bin/node"
let base = FileManager.default.temporaryDirectory.appendingPathComponent("ws-\(getpid())")
try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

let serverScript = """
const { WebSocketServer } = require('ws');
const port = Number(process.argv[2]);
const server = new WebSocketServer({ port: port, host: '127.0.0.1' });
server.on('connection', socket => {
  socket.on('message', data => {
    const text = data.toString();
    if (text === 'bye') { socket.close(); return; }
    socket.send('echo:' + text);
  });
  socket.send('welcome');
});
"""

let clientScript = """
const WebSocket = require('ws');
const port = Number(process.argv[2]);
function attempt(left) {
  const socket = new WebSocket('ws://127.0.0.1:' + port);
  const seen = [];
  socket.on('open', () => { console.log('open'); socket.send('one'); });
  socket.on('message', data => {
    const text = data.toString();
    seen.push(text);
    console.log('message', text);
    if (text === 'echo:one') socket.send('two');
    else if (text === 'echo:two') socket.send('bye');
  });
  socket.on('close', () => console.log('close; saw', seen.length, 'messages'));
  socket.on('error', error => {
    if (left > 0) setTimeout(() => attempt(left - 1), 150);
    else console.log('error', error.code || error.message);
  });
}
attempt(40);
// A stalled exchange must still produce a comparable transcript.
setTimeout(() => { console.log('timeout'); process.exit(0); }, 6000);
"""

func freePort() -> Int {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafePointer(to: &address) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    var bound = sockaddr_in()
    _ = withUnsafeMutablePointer(to: &bound) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        getsockname(fd, $0, &length) } }
    close(fd)
    return Int(UInt16(bigEndian: bound.sin_port))
}

print("installing ws with our own package manager…")
do { _ = try await PackageManager.install(requirements: ["ws": "^8.18.0"], into: base) }
catch { print("FAIL: install: \(error)"); exit(1) }

func write(_ text: String, _ name: String, _ dir: URL) {
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try? text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
}
write(serverScript, "server.js", base)
write(clientScript, "client.js", base)

func runNode(_ entry: String, _ port: Int, wait: Bool) -> (process: Process, out: Pipe, err: Pipe) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: realNode)
    process.arguments = [entry, String(port)]
    process.currentDirectoryURL = base
    let out = Pipe(), err = Pipe()
    process.standardOutput = out
    process.standardError = err
    try? process.run()
    if wait { process.waitUntilExit() }
    return (process, out, err)
}

func text(_ pipe: Pipe) -> String { String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) }

func serveOurs(_ entry: String, _ port: Int) -> Task<Void, Never> {
    let source = try! String(contentsOf: base.appendingPathComponent(entry), encoding: .utf8)
    return Task.detached {
        let engine = NodeEngine(root: base, env: ["PATH": "/"])
        let result = await engine.run(source: source, path: "/" + entry,
                                      argv: ["node", "/" + entry, String(port)], cwd: "/", stdin: "")
        if !result.err.isEmpty { FileHandle.standardError.write("engine stderr (\(entry)): \(result.err)\n".data(using: .utf8)!) }
        if !result.out.isEmpty { FileHandle.standardError.write("engine stdout (\(entry)): \(result.out)\n".data(using: .utf8)!) }
    }
}

var failures = 0

// 1. Our ws SERVER, a real node ws client.
do {
    let port = freePort()
    let ourServer = serveOurs("server.js", port)
    try? await Task.sleep(nanoseconds: 1_500_000_000)
    let client = runNode("client.js", port, wait: true)
    ourServer.cancel()
    let againstOurs = text(client.out)

    let realPort = freePort()
    let realServer = runNode("server.js", realPort, wait: false)
    try? await Task.sleep(nanoseconds: 800_000_000)
    let realClient = runNode("client.js", realPort, wait: true)
    let againstReal = text(realClient.out)
    realServer.process.terminate()

    if againstOurs == againstReal, !againstOurs.isEmpty {
        print("ws SERVER on our engine — a real node ws client cannot tell it from node's:")
        print(againstOurs, terminator: "")
    } else {
        failures += 1
        print("MISMATCH: our ws server")
        print("  ours: \(againstOurs.debugDescription)\n  real: \(againstReal.debugDescription)")
        let errors = text(client.err)
        if !errors.isEmpty { print("  client stderr: \(errors)") }
    }
}

// 2. Our ws CLIENT, a real node ws server.
do {
    let port = freePort()
    let realServer = runNode("server.js", port, wait: false)
    try? await Task.sleep(nanoseconds: 800_000_000)
    let source = try! String(contentsOf: base.appendingPathComponent("client.js"), encoding: .utf8)
    let engine = NodeEngine(root: base, env: ["PATH": "/"])
    let ours = await engine.run(source: source, path: "/client.js",
                                argv: ["node", "/client.js", String(port)], cwd: "/", stdin: "")
    realServer.process.terminate()

    let realPort = freePort()
    let realServer2 = runNode("server.js", realPort, wait: false)
    try? await Task.sleep(nanoseconds: 800_000_000)
    let real = runNode("client.js", realPort, wait: true)
    let realOut = text(real.out)
    realServer2.process.terminate()

    if ours.out == realOut, !ours.out.isEmpty {
        print("ws CLIENT on our engine — a real node ws server cannot tell it from node's")
    } else {
        failures += 1
        print("MISMATCH: our ws client")
        print("  ours: \(ours.out.debugDescription) stderr: \(ours.err.debugDescription)")
        print("  real: \(realOut.debugDescription)")
    }
}

try? FileManager.default.removeItem(at: base)
print(failures == 0 ? "WS: ALL PASS" : "\(failures) FAILURES")
exit(failures == 0 ? 0 : 1)
