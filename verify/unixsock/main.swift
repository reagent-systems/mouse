import Foundation
setvbuf(stdout, nil, _IONBF, 0)

// Unix domain sockets, cross-engine over a real socket FILE: ours serves and real node connects,
// then the reverse. A socket file is the one address family where the peer and the filesystem
// have to agree, so a stale file from a previous run is part of the contract.
let realNode = "/Users/thyfriendlyfox/.local/bin/node"
let base = FileManager.default.temporaryDirectory.appendingPathComponent("unixsock-\(getpid())")
try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

let server = """
const net = require('net');
const server = net.createServer(socket => {
  socket.on('data', chunk => socket.write('echo:' + chunk));
  socket.on('end', () => { console.log('server: peer ended'); server.close(); });
});
server.listen(process.argv[2], () => console.log('listening on a socket file'));
"""
let client = """
const net = require('net');
const socket = net.connect({ path: process.argv[2] }, () => socket.write('over a file'));
socket.setEncoding('utf8');
socket.on('data', chunk => { console.log('client: ' + chunk); socket.end(); });
socket.on('error', error => console.log('client error: ' + error.code));
"""
try? server.write(to: base.appendingPathComponent("server.js"), atomically: true, encoding: .utf8)
try? client.write(to: base.appendingPathComponent("client.js"), atomically: true, encoding: .utf8)

func runNode(_ entry: String, _ path: String, wait: Bool) -> (Process, Pipe) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: realNode)
    process.arguments = [entry, path]
    process.currentDirectoryURL = base
    let out = Pipe()
    process.standardOutput = out
    process.standardError = Pipe()
    try? process.run()
    if wait { process.waitUntilExit() }
    return (process, out)
}
func text(_ pipe: Pipe) -> String { String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) }

// 1. Ours serves on the file; real node connects. The engine's paths are workspace-virtual, so
// the server is told "/a.sock" while node is told the real path to the same file.
let ourSocket = base.appendingPathComponent("a.sock").path
let serving = Task.detached {
    let engine = NodeEngine(root: base, env: ["PATH": "/"])
    let result = await engine.run(source: server, path: "/server.js",
                                  argv: ["node", "/server.js", "/a.sock"], cwd: "/", stdin: "")
    if !result.err.isEmpty { FileHandle.standardError.write("ours server stderr: \(result.err)\n".data(using: .utf8)!) }
}
try? await Task.sleep(nanoseconds: 900_000_000)
let (clientProcess, clientOut) = runNode("client.js", ourSocket, wait: false)
for _ in 0..<40 where clientProcess.isRunning { try? await Task.sleep(nanoseconds: 100_000_000) }
if clientProcess.isRunning { clientProcess.terminate() }
let realClientSaw = text(clientOut)
serving.cancel()

// 2. Real node serves; ours connects.
let theirSocket = base.appendingPathComponent("b.sock").path
let (serverProcess, serverOut) = runNode("server.js", theirSocket, wait: false)
try? await Task.sleep(nanoseconds: 800_000_000)
let engine = NodeEngine(root: base, env: ["PATH": "/"])
let oursClient = await engine.run(source: client, path: "/client.js",
                                  argv: ["node", "/client.js", "/b.sock"], cwd: "/", stdin: "")
for _ in 0..<30 where serverProcess.isRunning { try? await Task.sleep(nanoseconds: 100_000_000) }
if serverProcess.isRunning { serverProcess.terminate() }
let realServerSaw = text(serverOut)

if !oursClient.err.isEmpty { print("ours client stderr: \(oursClient.err.prefix(400))") }
print("real client saw: \(realClientSaw)ours client saw: \(oursClient.out)real server saw: \(realServerSaw)")

let expected = "client: echo:over a file\n"
if realClientSaw == expected, oursClient.out == expected,
   realServerSaw.contains("listening on a socket file"), realServerSaw.contains("peer ended") {
    print("UNIX SOCKET MATCH — a socket file works in both directions with real node")
} else {
    print("MISMATCH")
    exit(1)
}
try? FileManager.default.removeItem(at: base)
