import Foundation
setvbuf(stdout, nil, _IONBF, 0)

// The standard WebSocket global, compared against node 22's own. The server is real node
// running the `ws` package, so both clients talk to an identical peer — and ours rides
// URLSession's WebSocket task, the only path that can also do wss://.

let realNode = "/Users/thyfriendlyfox/.local/bin/node"
let base = FileManager.default.temporaryDirectory.appendingPathComponent("wsglobal-\(getpid())")
try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

print("installing ws (for the SERVER side) with our own package manager…")
do { _ = try await PackageManager.install(requirements: ["ws": "^8.18.0"], into: base) }
catch { print("FAIL: install: \(error)"); exit(1) }

let serverScript = """
const { WebSocketServer } = require('ws');
const server = new WebSocketServer({ port: Number(process.argv[2]), host: '127.0.0.1' });
server.on('connection', socket => {
  socket.on('message', (data, isBinary) => {
    const text = data.toString();
    if (text === 'bye') { socket.close(1000, 'done'); return; }
    socket.send(isBinary ? Buffer.from('bin:' + text) : 'echo:' + text, { binary: isBinary });
  });
  socket.send('welcome');
});
setTimeout(() => process.exit(0), 12000);
"""

// The client uses ONLY the standard API — no `ws` require — so it runs identically under both.
let clientScript = """
const port = Number(process.argv[2]);
const seen = [];
const socket = new WebSocket('ws://127.0.0.1:' + port);
socket.binaryType = 'arraybuffer';
socket.addEventListener('open', () => { seen.push('open'); socket.send('one'); });
socket.addEventListener('message', event => {
  const text = typeof event.data === 'string' ? event.data : Buffer.from(event.data).toString();
  seen.push('message:' + text);
  if (text === 'echo:one') socket.send(new Uint8Array([104, 105]));       // binary frame
  else if (text === 'bin:hi') socket.send('bye');
});
socket.addEventListener('close', event => {
  seen.push('close:' + event.code + ':' + event.wasClean);
  console.log(seen.join(' '));
  console.log('constants:', WebSocket.CONNECTING, WebSocket.OPEN, WebSocket.CLOSING, WebSocket.CLOSED);
  process.exit(0);
});
setTimeout(() => { console.log('TIMEOUT ' + seen.join(' ')); process.exit(0); }, 8000);
"""

func write(_ text: String, _ name: String) {
    try? text.write(to: base.appendingPathComponent(name), atomically: true, encoding: .utf8)
}
write(serverScript, "server.js")
write(clientScript, "client.js")

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

func runNodeServer(_ port: Int) -> Process {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: realNode)
    process.arguments = ["server.js", String(port)]
    process.currentDirectoryURL = base
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    try? process.run()
    return process
}

// ours
let ourPort = freePort()
let server1 = runNodeServer(ourPort)
try? await Task.sleep(nanoseconds: 900_000_000)
let engine = NodeEngine(root: base, env: ["PATH": "/"])
let ours = await engine.run(source: clientScript, path: "/client.js",
                            argv: ["node", "/client.js", String(ourPort)], cwd: "/", stdin: "")
server1.terminate()

// real node 22's own global WebSocket
let realPort = freePort()
let server2 = runNodeServer(realPort)
try? await Task.sleep(nanoseconds: 900_000_000)
let client = Process()
client.executableURL = URL(fileURLWithPath: realNode)
client.arguments = ["client.js", String(realPort)]
client.currentDirectoryURL = base
let out = Pipe()
client.standardOutput = out
client.standardError = Pipe()
try? client.run()
client.waitUntilExit()
let real = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
server2.terminate()

if ours.out == real, !ours.out.isEmpty, !ours.out.contains("TIMEOUT") {
    print("WEBSOCKET GLOBAL MATCH — the standard API behaves as node 22's does:")
    print(ours.out, terminator: "")
} else {
    print("MISMATCH")
    print("  ours: \(ours.out.debugDescription)")
    print("  ours stderr: \(ours.err.debugDescription)")
    print("  real: \(real.debugDescription)")
    exit(1)
}
try? FileManager.default.removeItem(at: base)
