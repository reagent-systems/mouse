import Foundation
setvbuf(stdout, nil, _IONBF, 0)

// UDP, cross-engine. A datagram socket is only interesting if a real peer can talk to it, so
// real node binds one and ours exchanges packets with it — and then the reverse. Datagrams carry
// their sender, so the reply address comes from the packet itself, not from a connection.
let realNode = "/Users/thyfriendlyfox/.local/bin/node"
let base = FileManager.default.temporaryDirectory.appendingPathComponent("udp-\(getpid())")
try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

// An echo server: replies to whoever sent, then reports what it saw.
let server = """
const dgram = require('dgram');
const socket = dgram.createSocket('udp4');
const seen = [];
socket.on('message', (message, rinfo) => {
  seen.push(String(message) + '@' + (rinfo.size) + (rinfo.port > 0 ? '+port' : ''));
  if (String(message) === 'stop') {
    console.log('server saw: ' + seen.join(' | '));
    socket.close();
    return;
  }
  socket.send('echo:' + message, rinfo.port, rinfo.address);
});
socket.bind(Number(process.argv[2]), '127.0.0.1', () => {
  const address = socket.address();
  console.log('bound family ' + address.family + ' port is number: ' + (typeof address.port === 'number'));
});
"""
let client = """
const dgram = require('dgram');
const socket = dgram.createSocket('udp4');
const port = Number(process.argv[2]);
const seen = [];
socket.on('message', (message, rinfo) => {
  seen.push(String(message));
  if (seen.length < 2) socket.send('second', port, '127.0.0.1');
  else {
    socket.send('stop', port, '127.0.0.1', () => {
      console.log('client saw: ' + seen.join(' | '));
      socket.close();
    });
  }
});
socket.send('first', port, '127.0.0.1', error => {
  if (error) console.log('send failed: ' + error.message);
});
"""
try? server.write(to: base.appendingPathComponent("server.js"), atomically: true, encoding: .utf8)
try? client.write(to: base.appendingPathComponent("client.js"), atomically: true, encoding: .utf8)

func freePort() -> Int { 9800 + Int(getpid()) % 150 }

func runNode(_ entry: String, _ port: Int, wait: Bool) -> (Process, Pipe) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: realNode)
    process.arguments = [entry, String(port)]
    process.currentDirectoryURL = base
    let out = Pipe()
    process.standardOutput = out
    process.standardError = Pipe()
    try? process.run()
    if wait { process.waitUntilExit() }
    return (process, out)
}
func text(_ pipe: Pipe) -> String { String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) }

// 1. Real node serves, ours is the client.
let portA = freePort()
let (serverA, serverAOut) = runNode("server.js", portA, wait: false)
try? await Task.sleep(nanoseconds: 700_000_000)
let engineA = NodeEngine(root: base, env: ["PATH": "/"])
let oursClient = await engineA.run(source: client, path: "/client.js",
                                   argv: ["node", "/client.js", String(portA)], cwd: "/", stdin: "")
// Bounded: a peer that never finishes must not hide the diagnostics.
for _ in 0..<40 where serverA.isRunning { try? await Task.sleep(nanoseconds: 100_000_000) }
if serverA.isRunning { serverA.terminate() }
let realServerSaw = text(serverAOut)

// 2. Ours serves, real node is the client.
let portB = freePort() + 1
let engineB = NodeEngine(root: base, env: ["PATH": "/"])
let serving = Task.detached {
    _ = await engineB.run(source: server, path: "/server.js",
                          argv: ["node", "/server.js", String(portB)], cwd: "/", stdin: "")
}
try? await Task.sleep(nanoseconds: 700_000_000)
let (clientB, clientBOut) = runNode("client.js", portB, wait: false)
for _ in 0..<40 where clientB.isRunning { try? await Task.sleep(nanoseconds: 100_000_000) }
if clientB.isRunning { clientB.terminate() }
let realClientSaw = text(clientBOut)
try? await Task.sleep(nanoseconds: 400_000_000)
serving.cancel()

// 3. Multicast: join a group on loopback, send to it, receive your own packet.
let multicast = #"""
const dgram = require('dgram');
const socket = dgram.createSocket({ type: 'udp4', reuseAddr: true });
const group = '239.255.42.99';
socket.on('message', (message, rinfo) => {
  console.log('received: ' + message + '@' + (rinfo.port > 0 ? 'port' : 'noport'));
  socket.close();
});
socket.bind(Number(process.argv[2]), () => {
  socket.setMulticastInterface('127.0.0.1');
  socket.setMulticastLoopback(true);
  socket.setMulticastTTL(1);
  socket.addMembership(group, '127.0.0.1');
  console.log('joined ' + group);
  socket.send('hello group', Number(process.argv[2]), group);
});
setTimeout(() => { console.log('done'); process.exit(0); }, 2000);
"""#
try? multicast.write(to: base.appendingPathComponent("mcast.js"), atomically: true, encoding: .utf8)
let portC = freePort() + 2
let engineC = NodeEngine(root: base, env: ["PATH": "/"])
let oursMulticast = await engineC.run(source: multicast, path: "/mcast.js",
                                      argv: ["node", "/mcast.js", String(portC)], cwd: "/", stdin: "")
let (_, realMulticastOut) = runNode("mcast.js", portC + 1, wait: true)
let realMulticast = text(realMulticastOut)

if !oursClient.err.isEmpty { print("ours stderr: \(oursClient.err.prefix(500))") }
print("ours multicast: \(oursMulticast.out)real multicast: \(realMulticast)")
print("ours as client: \(oursClient.out)real server saw: \(realServerSaw)real client saw: \(realClientSaw)")

let expectedClient = "client saw: echo:first | echo:second\n"
if oursClient.out == expectedClient,
   realServerSaw.contains("server saw: first@5+port | second@6+port | stop@4+port"),
   realClientSaw == expectedClient,
   oursMulticast.out == realMulticast, oursMulticast.out.contains("received: hello group@port") {
    print("UDP MATCH — datagrams both ways with real node, and multicast joins, sends and receives")
} else {
    print("MISMATCH")
    exit(1)
}
try? FileManager.default.removeItem(at: base)
