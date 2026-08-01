import Foundation

// Phase G verification for REAL TCP (`net`), per AGENTS.md. Three kinds of proof:
//   1. twin-engine — the same script through NodeEngine and through real node, stdout and
//      exit status compared (server and client both inside one script);
//   2. our server ← REAL node client, compared against the same client talking to a real
//      node server (so the bytes on the wire are what node's client expects);
//   3. our client → REAL node server, compared against real node's client against the same
//      server (so what we put on the wire is what node's server accepts).
// Ports come from the OS (listen on 0) wherever a fixture can learn its own port; the
// cross-engine cases need a fixed port, so the harness reserves one by binding it first.

let realNode = "/Users/thyfriendlyfox/.local/bin/node"

func runReal(script: String, argv: [String], dir: URL, entry: String = "main.js") -> (out: String, status: Int32) {
    try? script.write(to: dir.appendingPathComponent(entry), atomically: true, encoding: .utf8)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: realNode)
    process.arguments = [entry] + argv
    process.currentDirectoryURL = dir
    let out = Pipe()
    process.standardOutput = out
    process.standardError = Pipe()
    try? process.run()
    process.waitUntilExit()
    return (String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), process.terminationStatus)
}

func runOurs(script: String, argv: [String], dir: URL, entry: String = "main.js") async -> (out: String, status: Int32) {
    try? script.write(to: dir.appendingPathComponent(entry), atomically: true, encoding: .utf8)
    let engine = NodeEngine(root: dir, env: ["PATH": "/"])
    let result = await engine.run(source: script, path: "/" + entry,
                                  argv: ["node", "/" + entry] + argv, cwd: "/", stdin: "")
    return (result.out, result.status)
}

/// Start a real-node process without waiting for it — the cross-engine cases need a peer
/// running WHILE the other engine runs.
func spawnReal(script: String, argv: [String], dir: URL, entry: String) -> (process: Process, out: Pipe) {
    try? script.write(to: dir.appendingPathComponent(entry), atomically: true, encoding: .utf8)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: realNode)
    process.arguments = [entry] + argv
    process.currentDirectoryURL = dir
    let out = Pipe()
    process.standardOutput = out
    process.standardError = Pipe()
    try? process.run()
    return (process, out)
}

/// A port nobody is on: bind it, read it back, release it. Racy in principle, fine in a
/// harness — and far better than hardcoding.
func freePort() -> Int {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    var bound = sockaddr_in()
    _ = withUnsafeMutablePointer(to: &bound) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
    }
    close(fd)
    return Int(UInt16(bigEndian: bound.sin_port))
}

var failures = 0
let base = FileManager.default.temporaryDirectory.appendingPathComponent("net-verify-\(getpid())")

func directory(_ name: String) -> URL {
    let url = base.appendingPathComponent(name)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func compare(_ name: String, ours: (out: String, status: Int32), real: (out: String, status: Int32)) {
    if ours.out == real.out && ours.status == real.status {
        print("fixture \(name): match")
    } else {
        failures += 1
        print("MISMATCH: \(name) (status ours=\(ours.status) real=\(real.status))")
        print("  ---- ours ----\n\(ours.out)  ---- real ----\n\(real.out)  --------------")
    }
}

// MARK: - 1. Twin-engine fixtures (server and client in one script)

let fixtures: [(name: String, script: String)] = [
    // Two views of one exchange, each logging ONE socket's events. The relative order of
    // events on two different sockets is poll-order dependent (a known divergence: node
    // reports the server's 'connection' before the client's 'connect'; we report the
    // reverse), so a fixture that logs both interleaved would assert something node does not
    // promise. Each socket's OWN sequence is a real contract, and that is what these check.
    ("net-echo-client-view", """
    const net = require('net');
    const server = net.createServer(socket => {
      socket.on('data', chunk => socket.write('echo:' + chunk));
      socket.on('end', () => socket.end());
    });
    server.listen(0, '127.0.0.1', () => {
      const address = server.address();
      console.log('listening', address.address, address.family, typeof address.port);
      const client = net.connect(address.port, '127.0.0.1', () => {
        console.log('connect; remotePort is number:', typeof client.remotePort === 'number');
        client.write('ping');
      });
      client.setEncoding('utf8');
      client.on('data', chunk => { console.log('data', chunk); client.end(); });
      client.on('end', () => console.log('end'));
      client.on('close', () => {
        console.log('close; read', client.bytesRead, 'wrote', client.bytesWritten,
                    'destroyed', client.destroyed);
        server.close();
      });
    });
    """),

    ("net-echo-server-view", """
    const net = require('net');
    const server = net.createServer(socket => {
      console.log('connection from', socket.remoteAddress, 'family', socket.remoteFamily);
      socket.on('data', chunk => { console.log('data', JSON.stringify(String(chunk))); socket.write('echo:' + chunk); });
      socket.on('end', () => console.log('end'));
      socket.on('close', () => { console.log('close; read', socket.bytesRead, 'wrote', socket.bytesWritten); server.close(); });
    });
    server.listen(0, '127.0.0.1', () => {
      const client = net.connect(server.address().port, '127.0.0.1', () => client.write('ping'));
      client.on('data', () => client.end());
    });
    """),

    // The peer's FIN must arrive as 'end' and not as an error, and a socket the server never
    // writes to must still close cleanly on both sides.
    ("net-half-close", """
    const net = require('net');
    const server = net.createServer(socket => {
      socket.end('bye\\n');
    });
    server.listen(0, '127.0.0.1', () => {
      const client = net.connect(server.address().port, '127.0.0.1');
      let body = '';
      client.on('data', chunk => body += chunk);
      client.on('end', () => console.log('client: end, body =', JSON.stringify(body)));
      client.on('close', () => { console.log('client: close'); server.close(); });
    });
    """),

    // 1 MB through a 64 KB kernel queue: this is the path where write() returns false and
    // the _write callback waits on the host's 'drain'. Sizes only — chunk boundaries differ
    // between engines and are not part of the contract.
    ("net-backpressure", """
    const net = require('net');
    const payload = Buffer.alloc(1024 * 1024, 0x61);
    const server = net.createServer(socket => {
      let received = 0;
      socket.on('data', chunk => received += chunk.length);
      socket.on('end', () => { console.log('server: received', received); socket.end(); });
    });
    server.listen(0, '127.0.0.1', () => {
      const client = net.connect(server.address().port, '127.0.0.1', () => {
        const accepted = client.write(payload);
        console.log('client: write accepted immediately:', typeof accepted === 'boolean');
        client.end();
      });
      client.on('close', () => { console.log('client: wrote', client.bytesWritten); server.close(); });
    });
    """),

    ("net-refused", """
    const net = require('net');
    // Port 1 on loopback: nothing listens, and binding it needs root, so this is reliably
    // a refusal rather than an accident.
    const socket = net.connect(1, '127.0.0.1');
    socket.on('error', error => console.log('error code:', error.code));
    socket.on('close', () => console.log('closed after error'));
    """),

    ("net-address-in-use", """
    const net = require('net');
    const first = net.createServer();
    first.listen(0, '127.0.0.1', () => {
      const port = first.address().port;
      const second = net.createServer();
      second.on('error', error => {
        console.log('second server error:', error.code);
        first.close(() => console.log('first closed'));
      });
      second.listen(port, '127.0.0.1', () => console.log('UNEXPECTED: second listen succeeded'));
    });
    """),

    ("net-many-connections", """
    const net = require('net');
    const server = net.createServer(socket => {
      socket.on('data', chunk => socket.end('re:' + chunk));
    });
    server.listen(0, '127.0.0.1', () => {
      const port = server.address().port;
      let done = 0;
      const replies = [];
      for (let i = 0; i < 5; i++) {
        const client = net.connect(port, '127.0.0.1', function(){ this.write('n' + i); });
        client.setEncoding('utf8');
        client.on('data', chunk => replies.push(chunk));
        client.on('close', () => {
          if (++done === 5) {
            // Every reply arrived and every client closed exactly once. How many server-side
            // sockets are still live at this instant is NOT specified — real node answers 1,
            // 2 or 3 across runs — so the count itself is not asserted, only its type.
            console.log('replies:', replies.sort().join(','));
            server.getConnections((error, count) => {
              console.log('closes:', done, 'getConnections gives a number:', typeof count === 'number');
              server.close(() => console.log('server closed'));
            });
          }
        });
      }
    });
    """),

    // Server-side flow control: the consumer pauses, the fd stops being read, and no bytes
    // are lost when it resumes.
    ("net-pause-resume", """
    const net = require('net');
    const server = net.createServer(socket => {
      socket.pause();
      let total = 0;
      setTimeout(() => {
        socket.on('data', chunk => total += chunk.length);
        socket.on('end', () => { console.log('server: total after resume', total); socket.end(); });
        socket.resume();
      }, 50);
    });
    server.listen(0, '127.0.0.1', () => {
      const client = net.connect(server.address().port, '127.0.0.1', () => {
        client.write(Buffer.alloc(4096, 0x62));
        client.end();
      });
      client.on('close', () => server.close());
    });
    """),

    ("net-helpers", """
    const net = require('net');
    console.log(net.isIP('127.0.0.1'), net.isIP('::1'), net.isIP('nope'));
    console.log(net.isIPv4('10.0.0.1'), net.isIPv6('fe80::1'));
    console.log(typeof net.createServer, typeof net.connect, typeof net.Socket);
    """),

    // An unref'd server must not hold the loop open: this script has to EXIT.
    ("net-unref", """
    const net = require('net');
    const server = net.createServer();
    server.listen(0, '127.0.0.1', () => { server.unref(); console.log('listening then unref'); });
    setTimeout(() => console.log('timer ran, now nothing keeps us alive'), 10);
    """),
]

for fixture in fixtures {
    let ours = await runOurs(script: fixture.script, argv: [], dir: directory("ours-\(fixture.name)"))
    let real = runReal(script: fixture.script, argv: [], dir: directory("real-\(fixture.name)"))
    compare(fixture.name, ours: ours, real: real)
}

// MARK: - 2. Our server ← a REAL node client

// The client is byte-identical in both runs; only the server changes. If our server speaks
// TCP correctly, node's client cannot tell the difference.
let clientScript = """
const net = require('net');
const port = Number(process.argv[2]);
function attempt(left) {
  const socket = net.connect(port, '127.0.0.1');
  socket.setEncoding('utf8');
  let body = '';
  socket.on('connect', () => socket.write('HELLO'));
  socket.on('data', chunk => body += chunk);
  socket.on('end', () => console.log('client saw:', JSON.stringify(body)));
  socket.on('error', error => {
    if (left > 0 && (error.code === 'ECONNREFUSED' || error.code === 'ECONNRESET')) {
      setTimeout(() => attempt(left - 1), 100);
    } else {
      console.log('client error:', error.code);
    }
  });
}
attempt(40);
"""

let serverScript = """
const net = require('net');
const port = Number(process.argv[2]);
const server = net.createServer(socket => {
  socket.on('data', chunk => {
    console.log('server read:', JSON.stringify(String(chunk)));
    socket.end('ACK:' + chunk);
  });
  socket.on('end', () => server.close(() => console.log('server closed after one client')));
});
server.listen(port, '127.0.0.1');
"""

do {
    // Ours serving, real node connecting.
    let port = freePort()
    let clientDir = directory("cross-a-client")
    let client = spawnReal(script: clientScript, argv: [String(port)], dir: clientDir, entry: "client.js")
    let ourServer = await runOurs(script: serverScript, argv: [String(port)], dir: directory("cross-a-server"))
    client.process.waitUntilExit()
    let clientSawOurs = String(decoding: client.out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)

    // The same client against real node's server, for the byte comparison.
    let port2 = freePort()
    let clientDir2 = directory("cross-a-client-real")
    let client2 = spawnReal(script: clientScript, argv: [String(port2)], dir: clientDir2, entry: "client.js")
    let realServer = runReal(script: serverScript, argv: [String(port2)], dir: directory("cross-a-server-real"), entry: "server.js")
    client2.process.waitUntilExit()
    let clientSawReal = String(decoding: client2.out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)

    if clientSawOurs == clientSawReal, ourServer.out == realServer.out, ourServer.status == realServer.status {
        print("cross-engine: a real node CLIENT cannot tell our server from node's")
    } else {
        failures += 1
        print("MISMATCH: cross-engine our-server/real-client")
        print("  client saw (ours=\(clientSawOurs.debugDescription)) (real=\(clientSawReal.debugDescription))")
        print("  server said (ours=\(ourServer.out.debugDescription)) (real=\(realServer.out.debugDescription))")
    }
}

// MARK: - 3. Our client → a REAL node server

do {
    let port = freePort()
    let server = spawnReal(script: serverScript, argv: [String(port)], dir: directory("cross-b-server"), entry: "server.js")
    // Give it a moment to bind; the client retries anyway.
    try? await Task.sleep(nanoseconds: 300_000_000)
    let ourClient = await runOurs(script: clientScript, argv: [String(port)], dir: directory("cross-b-client"))
    server.process.waitUntilExit()
    let serverSawOurs = String(decoding: server.out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)

    let port2 = freePort()
    let server2 = spawnReal(script: serverScript, argv: [String(port2)], dir: directory("cross-b-server-real"), entry: "server.js")
    try? await Task.sleep(nanoseconds: 300_000_000)
    let realClient = runReal(script: clientScript, argv: [String(port2)], dir: directory("cross-b-client-real"))
    server2.process.waitUntilExit()
    let serverSawReal = String(decoding: server2.out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)

    if serverSawOurs == serverSawReal, ourClient.out == realClient.out, ourClient.status == realClient.status {
        print("cross-engine: a real node SERVER cannot tell our client from node's")
    } else {
        failures += 1
        print("MISMATCH: cross-engine our-client/real-server")
        print("  server saw (ours=\(serverSawOurs.debugDescription)) (real=\(serverSawReal.debugDescription))")
        print("  client said (ours=\(ourClient.out.debugDescription)) (real=\(realClient.out.debugDescription))")
    }
}

try? FileManager.default.removeItem(at: base)
print(failures == 0 ? "PHASE G NET: ALL PASS" : "\(failures) FAILURES")
exit(failures == 0 ? 0 : 1)
