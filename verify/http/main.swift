import Foundation

// Phase G verification for `http.createServer`, per AGENTS.md. The decisive check is at the
// WIRE: the same raw-socket client (a literal request string, the exact response bytes back)
// runs against our server and against real node's, and the bytes must match — that is the
// only way to know our framing, header order and keep-alive behavior are node's and not
// merely plausible. Plus twin-engine fixtures for the API surface, and a real node client
// (http.get) against our server.

setvbuf(stdout, nil, _IONBF, 0)   // a watchdog kill must not swallow progress
let realNode = "/Users/thyfriendlyfox/.local/bin/node"
func mark(_ text: String) { FileHandle.standardError.write("MARK \(text)\n".data(using: .utf8)!) }
var failures = 0
let base = FileManager.default.temporaryDirectory.appendingPathComponent("http-verify-\(getpid())")

func directory(_ name: String) -> URL {
    let url = base.appendingPathComponent(name)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

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

/// Our engine, running a server that never exits on its own. The task is cancelled once the
/// peer is done — the engine honors cancellation (exit 130), which is also the only way a
/// listening server ever stops in-process.
func serveOurs(script: String, argv: [String], dir: URL) -> Task<Void, Never> {
    try? script.write(to: dir.appendingPathComponent("main.js"), atomically: true, encoding: .utf8)
    return Task.detached {
        let engine = NodeEngine(root: dir, env: ["PATH": "/"])
        _ = await engine.run(source: script, path: "/main.js",
                             argv: ["node", "/main.js"] + argv, cwd: "/", stdin: "")
    }
}

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

func freePort() -> Int {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafePointer(to: &address) { p in
        p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    var bound = sockaddr_in()
    _ = withUnsafeMutablePointer(to: &bound) { p in
        p.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
    }
    close(fd)
    return Int(UInt16(bigEndian: bound.sin_port))
}

// The server under test: identical source for both engines.
let serverScript = """
const http = require('http');
const server = http.createServer((req, res) => {
  if (req.url === '/plain') { res.end('hello'); return; }
  if (req.url === '/len') { res.setHeader('Content-Length', 5); res.setHeader('X-Custom', 'yes'); res.end('hello'); return; }
  if (req.url === '/chunks') { res.setHeader('Content-Type', 'text/plain'); res.write('one'); res.write('two'); res.end(); return; }
  if (req.url === '/code') { res.writeHead(404, { 'X-A': '1' }); res.end('nope'); return; }
  if (req.url === '/echo') { let b = ''; req.on('data', c => b += c); req.on('end', () => res.end('got:' + b + ':' + req.method)); return; }
  if (req.url === '/close') { res.setHeader('Connection', 'close'); res.end('bye'); return; }
  if (req.url === '/headers') { res.end(JSON.stringify({ host: req.headers.host, ua: req.headers['user-agent'] || null, dup: req.headers['x-dup'] })); return; }
  if (req.url === '/empty') { res.writeHead(204); res.end(); return; }
  res.end('default');
});
server.listen(Number(process.argv[2]), '127.0.0.1');
"""

// A raw-socket client: literal requests in, exact bytes out, Date normalized so runs compare.
let rawClientScript = """
const net = require('net');
const port = Number(process.argv[2]);
const requests = [
  'GET /plain HTTP/1.1\\r\\nHost: x\\r\\n\\r\\n',
  'GET /len HTTP/1.1\\r\\nHost: x\\r\\n\\r\\n',
  'GET /chunks HTTP/1.1\\r\\nHost: x\\r\\n\\r\\n',
  'GET /code HTTP/1.1\\r\\nHost: x\\r\\n\\r\\n',
  'POST /echo HTTP/1.1\\r\\nHost: x\\r\\nContent-Length: 4\\r\\n\\r\\nabcd',
  'POST /echo HTTP/1.1\\r\\nHost: x\\r\\nTransfer-Encoding: chunked\\r\\n\\r\\n3\\r\\nabc\\r\\n2\\r\\nde\\r\\n0\\r\\n\\r\\n',
  'HEAD /plain HTTP/1.1\\r\\nHost: x\\r\\n\\r\\n',
  'GET /close HTTP/1.1\\r\\nHost: x\\r\\n\\r\\n',
  'GET /headers HTTP/1.1\\r\\nHost: x\\r\\nX-Dup: one\\r\\nX-Dup: two\\r\\n\\r\\n',
  'GET /empty HTTP/1.1\\r\\nHost: x\\r\\n\\r\\n',
  'GET /plain HTTP/1.0\\r\\nHost: x\\r\\n\\r\\n',
  // Two requests down ONE socket: keep-alive plus pipelining.
  'GET /plain HTTP/1.1\\r\\nHost: x\\r\\n\\r\\nGET /code HTTP/1.1\\r\\nHost: x\\r\\n\\r\\n',
];
let i = 0;
function next() {
  if (i >= requests.length) { return; }
  const body = requests[i++];
  const socket = net.connect(port, '127.0.0.1', () => socket.write(body));
  let out = '';
  socket.setEncoding('utf8');
  socket.on('data', c => out += c);
  let finished = false;
  const done = () => {
    if (finished) return;
    finished = true;
    console.log('=== ' + JSON.stringify(body.split('\\r\\n')[0]));
    console.log(JSON.stringify(out.replace(/Date: [^\\r]+/g, 'Date: <NORM>')));
    next();
  };
  socket.on('end', done);
  socket.on('error', () => done());
  // Keep-alive responses never end the socket, so a short settle window is the only way to
  // know the response is complete.
  setTimeout(() => { if (!socket.destroyed) socket.destroy(); done(); }, 250);
}
next();
"""

// MARK: - The wire comparison

do {
    let ourPort = freePort()
    let ourServerDir = directory("ours-server")
    // Our server runs in-process; the raw client is real node, so the bytes are judged by node.
    let clientDir = directory("raw-client")
    mark("wire: ours serving")
    let ourServer = serveOurs(script: serverScript, argv: [String(ourPort)], dir: ourServerDir)
    try? await Task.sleep(nanoseconds: 400_000_000)
    let client = spawnReal(script: rawClientScript, argv: [String(ourPort)], dir: clientDir, entry: "raw.js")
    client.process.waitUntilExit()
    ourServer.cancel()
    let againstOurs = String(decoding: client.out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)

    mark("wire: real serving")
    let realPort = freePort()
    let realServer = spawnReal(script: serverScript, argv: [String(realPort)], dir: directory("real-server"), entry: "server.js")
    try? await Task.sleep(nanoseconds: 400_000_000)
    let againstReal = runReal(script: rawClientScript, argv: [String(realPort)], dir: directory("raw-client-real"), entry: "raw.js").out
    realServer.process.terminate()

    if againstOurs == againstReal, !againstOurs.isEmpty {
        let cases = againstOurs.components(separatedBy: "=== ").count - 1
        print("wire: our server's bytes are node's, across \(cases) request shapes")
    } else {
        failures += 1
        print("MISMATCH: wire bytes")
        let ourLines = againstOurs.components(separatedBy: "\n")
        let realLines = againstReal.components(separatedBy: "\n")
        for index in 0..<max(ourLines.count, realLines.count) {
            let a = index < ourLines.count ? ourLines[index] : "<none>"
            let b = index < realLines.count ? realLines[index] : "<none>"
            if a != b { print("  line \(index):\n    ours: \(a)\n    real: \(b)") }
        }
    }
}

// MARK: - A real node CLIENT against our server (http.get, not raw bytes)

do {
    let clientScript = """
    const http = require('http');
    const port = Number(process.argv[2]);
    function attempt(path, left, next) {
      const request = http.get({ host: '127.0.0.1', port: port, path: path }, res => {
        let body = '';
        res.on('data', c => body += c);
        res.on('end', () => {
          console.log(path, res.statusCode, JSON.stringify(body), 'type:', res.headers['content-type'] || 'none');
          next();
        });
      });
      request.on('error', error => {
        if (left > 0) setTimeout(() => attempt(path, left - 1, next), 100);
        else { console.log(path, 'ERROR', error.code); next(); }
      });
    }
    attempt('/plain', 40, () => attempt('/chunks', 5, () => attempt('/code', 5, () => {})));
    """
    let ourPort = freePort()
    mark("get: ours serving")
    let ourServer = serveOurs(script: serverScript, argv: [String(ourPort)], dir: directory("ours-server-2"))
    try? await Task.sleep(nanoseconds: 400_000_000)
    let client = spawnReal(script: clientScript, argv: [String(ourPort)], dir: directory("get-client"), entry: "get.js")
    client.process.waitUntilExit()
    ourServer.cancel()
    let fromOurs = String(decoding: client.out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)

    let realPort = freePort()
    mark("get: real serving")
    let realServer = spawnReal(script: serverScript, argv: [String(realPort)], dir: directory("real-server-2"), entry: "server.js")
    try? await Task.sleep(nanoseconds: 400_000_000)
    let fromReal = runReal(script: clientScript, argv: [String(realPort)], dir: directory("get-client-real"), entry: "get.js").out
    realServer.process.terminate()

    if fromOurs == fromReal, !fromOurs.isEmpty {
        print("client: node's http.get reads our server exactly as it reads node's")
    } else {
        failures += 1
        print("MISMATCH: http.get against our server")
        print("  ours: \(fromOurs.debugDescription)\n  real: \(fromReal.debugDescription)")
    }
}


// MARK: - The client's outgoing bytes, judged by a neutral raw TCP sink

// The mirror of the server wire test: a real-node raw socket sink prints exactly what it
// received, and our client's request bytes must equal node's for the same shapes. This is the
// only way to know our framing decisions (Content-Length vs chunked vs unframed, header order,
// Host and Connection) are node's rather than merely well-formed.
let sinkScript = """
const net = require('net');
let seen = 0;
const server = net.createServer(socket => {
  // Accumulate everything this connection sent, then report it SPLIT INTO REQUESTS. Neither
  // packet boundaries nor connection reuse are byte contracts: node's agent pools sockets and
  // sends two requests down one connection, we use one connection per request (a recorded
  // divergence). What must match is the bytes OF EACH REQUEST.
  let text = '';
  let timer = null;
  socket.on('data', chunk => {
    text += chunk;
    if (text.indexOf('\\r\\n\\r\\n') >= 0) {
      socket.write('HTTP/1.1 200 OK\\r\\nContent-Length: 2\\r\\n\\r\\nhi');
      if (timer) clearTimeout(timer);
      timer = setTimeout(report, 120);
    }
  });
  socket.on('end', () => { if (timer) clearTimeout(timer); report(); });
  function report() {
    if (!text) return;
    const body = text.replace(/Host: 127\\.0\\.0\\.1:\\d+/g, 'Host: 127.0.0.1:<PORT>');
    text = '';
    // Split on a REQUEST LINE, with the method spelled out: `[A-Z]+ /` also matches inside
    // "POST", so the old pattern shredded each request into single letters. It compared equal
    // only because both engines were shredded the same way.
    for (const one of body.split(/(?=(?:GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS|TRACE) \\/[^ ]* HTTP\\/1\\.1\\r\\n)/)) {
      if (one.trim()) { console.log(JSON.stringify(one)); seen++; }
    }
    if (seen >= 8) setTimeout(() => process.exit(0), 250);
  }
});
server.listen(Number(process.argv[2]), '127.0.0.1');
setTimeout(() => process.exit(0), 9000);
"""

// How many CONNECTIONS did the client open for N sequential requests? node's agent pools, so
// this is the number that used to differ.
let connectionSink = """
const net = require('net');
let connections = 0;
let requests = 0;
const server = net.createServer(socket => {
  connections++;
  let text = '';
  socket.on('data', chunk => {
    text += chunk;
    while (text.indexOf('\\r\\n\\r\\n') >= 0) {
      text = text.slice(text.indexOf('\\r\\n\\r\\n') + 4);
      requests++;
      socket.write('HTTP/1.1 200 OK\\r\\nContent-Length: 2\\r\\nConnection: keep-alive\\r\\n\\r\\nhi');
    }
  });
});
server.listen(Number(process.argv[2]), '127.0.0.1');
setTimeout(() => { console.log('requests=' + requests + ' connections=' + connections); process.exit(0); }, 3000);
"""

let sequentialClient = """
const http = require('http');
const port = Number(process.argv[2]);
function step(left) {
  if (!left) return;
  http.get({ host: '127.0.0.1', port: port, path: '/n' + left }, res => {
    res.resume();
    res.on('end', () => setTimeout(() => step(left - 1), 30));
  }).on('error', () => setTimeout(() => step(left - 1), 30));
}
step(4);
"""

let shapesScript = """
const http = require('http');
const port = Number(process.argv[2]);
const shapes = [
  [{ method: 'GET', path: '/a' }, r => r.end()],
  [{ method: 'POST', path: '/b', headers: { 'Content-Type': 'text/plain' } }, r => { r.write('hello'); r.end(); }],
  [{ method: 'GET', path: '/c', headers: { Connection: 'close' } }, r => r.end()],
  [{ method: 'POST', path: '/d' }, r => r.end('hello')],
  [{ method: 'POST', path: '/e', headers: { 'Content-Length': 5 } }, r => r.end('hello')],
  [{ method: 'POST', path: '/f' }, r => r.end()],
  [{ method: 'PUT', path: '/g' }, r => r.end()],
  [{ method: 'GET', path: '/h?x=1&y=2' }, r => r.end()],
];
function step(i) {
  if (i >= shapes.length) return;
  const [options, ender] = shapes[i];
  const request = http.request(Object.assign({ host: '127.0.0.1', port: port }, options), res => {
    res.resume();
    res.on('end', () => setTimeout(() => step(i + 1), 40));
  });
  request.on('error', () => setTimeout(() => step(i + 1), 40));
  ender(request);
}
step(0);
"""

do {
    let sinkPort = freePort()
    let sink = spawnReal(script: sinkScript, argv: [String(sinkPort)], dir: directory("sink-ours"), entry: "sink.js")
    try? await Task.sleep(nanoseconds: 500_000_000)
    _ = await runOurs(script: shapesScript, argv: [String(sinkPort)], dir: directory("shapes-ours"))
    sink.process.waitUntilExit()
    let sawOurs = String(decoding: sink.out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)

    let realSinkPort = freePort()
    let realSink = spawnReal(script: sinkScript, argv: [String(realSinkPort)], dir: directory("sink-real"), entry: "sink.js")
    try? await Task.sleep(nanoseconds: 500_000_000)
    _ = runReal(script: shapesScript, argv: [String(realSinkPort)], dir: directory("shapes-real"), entry: "shapes.js")
    realSink.process.waitUntilExit()
    let sawReal = String(decoding: realSink.out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)

    if sawOurs == sawReal, !sawOurs.isEmpty {
        let count = sawOurs.split(separator: "\n").count
        print("wire: our CLIENT's request bytes are node's, across \(count) shapes")
    } else {
        failures += 1
        print("MISMATCH: client wire bytes")
        let ourLines = sawOurs.components(separatedBy: "\n")
        let realLines = sawReal.components(separatedBy: "\n")
        for index in 0..<max(ourLines.count, realLines.count) {
            let a = index < ourLines.count ? ourLines[index] : "<none>"
            let b = index < realLines.count ? realLines[index] : "<none>"
            if a != b { print("  shape \(index):\n    ours: \(a)\n    real: \(b)") }
        }
    }
}

// MARK: - Connection reuse: four requests, and how many sockets it took

do {
    let ourPort = freePort()
    let sink = spawnReal(script: connectionSink, argv: [String(ourPort)], dir: directory("pool-sink-ours"), entry: "sink.js")
    try? await Task.sleep(nanoseconds: 400_000_000)
    _ = await runOurs(script: sequentialClient, argv: [String(ourPort)], dir: directory("pool-client-ours"))
    sink.process.waitUntilExit()
    let sawOurs = String(decoding: sink.out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)

    let realPort = freePort()
    let realSink = spawnReal(script: connectionSink, argv: [String(realPort)], dir: directory("pool-sink-real"), entry: "sink.js")
    try? await Task.sleep(nanoseconds: 400_000_000)
    _ = runReal(script: sequentialClient, argv: [String(realPort)], dir: directory("pool-client-real"), entry: "client.js")
    realSink.process.waitUntilExit()
    let sawReal = String(decoding: realSink.out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)

    if sawOurs == sawReal, sawOurs.contains("requests=4") {
        print("pool: four requests over the same number of connections as node — \(sawOurs.trimmingCharacters(in: .whitespacesAndNewlines))")
    } else {
        failures += 1
        print("MISMATCH: connection reuse\n  ours: \(sawOurs.debugDescription)\n  real: \(sawReal.debugDescription)")
    }
}

// MARK: - Twin-engine fixtures for the API surface

let fixtures: [(name: String, script: String)] = [
    // Server and client in one script: the round trip a dev server actually performs.
    ("http-round-trip", """
    const http = require('http');
    const server = http.createServer((req, res) => {
      res.setHeader('Content-Type', 'application/json');
      res.end(JSON.stringify({ method: req.method, url: req.url, hasHost: !!req.headers.host }));
    });
    server.listen(0, '127.0.0.1', () => {
      const port = server.address().port;
      http.get({ host: '127.0.0.1', port: port, path: '/api/thing' }, res => {
        let body = '';
        res.on('data', chunk => body += chunk);
        res.on('end', () => {
          console.log('status', res.statusCode);
          console.log('type', res.headers['content-type']);
          console.log('body', body);
          server.close(() => console.log('closed'));
        });
      });
    });
    """),

    ("http-post-body", """
    const http = require('http');
    const server = http.createServer((req, res) => {
      let body = '';
      req.on('data', chunk => body += chunk);
      req.on('end', () => {
        console.log('server got', req.method, req.url, JSON.stringify(body));
        res.writeHead(201, { 'X-Made': 'thing' });
        res.end('created');
      });
    });
    server.listen(0, '127.0.0.1', () => {
      const request = http.request({ host: '127.0.0.1', port: server.address().port,
                                     path: '/things', method: 'POST',
                                     headers: { 'Content-Type': 'text/plain' } }, res => {
        let body = '';
        res.on('data', chunk => body += chunk);
        res.on('end', () => {
          console.log('client got', res.statusCode, res.headers['x-made'], JSON.stringify(body));
          server.close();
        });
      });
      request.write('payload');
      request.end();
    });
    """),

    ("http-api-surface", """
    const http = require('http');
    console.log(typeof http.createServer, typeof http.Server, typeof http.ServerResponse);
    console.log(http.STATUS_CODES[404], http.STATUS_CODES[500]);
    console.log(http.METHODS.includes('GET'), http.METHODS.includes('PATCH'));
    const server = http.createServer();
    console.log('is a net.Server:', server instanceof require('net').Server);
    console.log('listening before listen:', server.listening);
    server.listen(0, '127.0.0.1', () => {
      console.log('listening after listen:', server.listening, typeof server.address().port);
      server.close(() => console.log('closed, listening:', server.listening));
    });
    """),

    // Header manipulation is a surface libraries lean on hard (express sets, gets, removes).
    ("http-header-api", """
    const http = require('http');
    const server = http.createServer((req, res) => {
      res.setHeader('X-One', '1');
      res.setHeader('X-Two', 'two');
      console.log('has X-One:', res.hasHeader('X-One'), 'get:', res.getHeader('x-one'));
      res.removeHeader('X-Two');
      console.log('names:', res.getHeaderNames().join(','));
      console.log('headersSent before:', res.headersSent);
      res.end('ok');
      console.log('headersSent after:', res.headersSent);
    });
    server.listen(0, '127.0.0.1', () => {
      http.get({ host: '127.0.0.1', port: server.address().port, path: '/' }, res => {
        console.log('x-one:', res.headers['x-one'], 'x-two:', res.headers['x-two']);
        res.on('data', () => {});
        res.on('end', () => server.close());
      });
    });
    """),

]

for fixture in fixtures {
    mark("fixture \(fixture.name)")
    let ours = await runOurs(script: fixture.script, argv: [], dir: directory("ours-\(fixture.name)"))
    let real = runReal(script: fixture.script, argv: [], dir: directory("real-\(fixture.name)"))
    if ours.out == real.out && ours.status == real.status {
        print("fixture \(fixture.name): match")
    } else {
        failures += 1
        print("MISMATCH: \(fixture.name) (status ours=\(ours.status) real=\(real.status))")
        print("  ---- ours ----\n\(ours.out)  ---- real ----\n\(real.out)  --------------")
    }
}

// A DELIBERATE divergence, so it cannot be a twin fixture: real node creates an https
// server happily (it fails later, when it needs a certificate). We refuse up front, because
// there is no TLS handshake to put on a raw socket, and say so.
do {
    let ours = await runOurs(script: """
    const https = require('https');
    try { https.createServer(); console.log('created'); }
    catch (error) { console.log('refused:', /TLS/.test(error.message)); }
    """, argv: [], dir: directory("https-refusal"))
    if ours.out == "refused: true\n" {
        print("https.createServer refuses with the TLS reason (node would create an unusable one)")
    } else {
        failures += 1
        print("MISMATCH: https refusal, got \(ours.out.debugDescription)")
    }
}

try? FileManager.default.removeItem(at: base)
print(failures == 0 ? "PHASE G HTTP: ALL PASS" : "\(failures) FAILURES")
exit(failures == 0 ? 0 : 1)
