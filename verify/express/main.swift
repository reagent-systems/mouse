import Foundation

// Real-package proof for http.createServer: a genuine express app, installed by OUR package
// manager, served by OUR engine, and exercised by REAL node's client — compared against the
// same app under real node. Express is the test that matters: it drives res.writeHead,
// header manipulation, streaming writes, 404 fallthrough and keep-alive all at once.

let realNode = "/Users/thyfriendlyfox/.local/bin/node"
let base = FileManager.default.temporaryDirectory.appendingPathComponent("express-\(getpid())")
try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

let app = """
const express = require('express');
const app = express();
app.get('/hello', (req, res) => res.send('hello world'));
app.get('/json', (req, res) => res.json({ ok: true, n: 42 }));
app.get('/code', (req, res) => res.status(418).send('teapot'));
app.post('/echo', express.json(), (req, res) => res.json({ got: req.body }));
app.get('/headers', (req, res) => { res.set('X-Mouse', 'yes'); res.type('text/plain'); res.send('headers'); });
const server = app.listen(Number(process.argv[2]), '127.0.0.1');
"""

let client = """
const http = require('http');
const port = Number(process.argv[2]);
function request(method, path, body, next) {
  const options = { host: '127.0.0.1', port: port, path: path, method: method, headers: {} };
  if (body) { options.headers['Content-Type'] = 'application/json'; options.headers['Content-Length'] = Buffer.byteLength(body); }
  const req = http.request(options, res => {
    let text = '';
    res.on('data', c => text += c);
    res.on('end', () => {
      console.log(method, path, res.statusCode,
                  'type=' + (res.headers['content-type'] || 'none'),
                  'x-mouse=' + (res.headers['x-mouse'] || 'none'),
                  JSON.stringify(text));
      next();
    });
  });
  req.on('error', error => { console.log(method, path, 'ERROR', error.code); next(); });
  if (body) req.write(body);
  req.end();
}
function retry(left, next) {
  const probe = http.get({ host: '127.0.0.1', port: port, path: '/hello' }, res => { res.resume(); next(); });
  probe.on('error', () => { if (left > 0) setTimeout(() => retry(left - 1, next), 100); else next(); });
}
retry(60, () => request('GET', '/hello', null, () =>
  request('GET', '/json', null, () =>
  request('GET', '/code', null, () =>
  request('POST', '/echo', JSON.stringify({ a: 1 }), () =>
  request('GET', '/headers', null, () =>
  request('GET', '/missing', null, () => {})))))));
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

// Install express with OUR package manager — the layout has to be right too.
print("installing express with our own package manager…")
do {
    _ = try await PackageManager.install(requirements: ["express": "^4.21.0"], into: base)
} catch {
    print("FAIL: install: \(error)")
    exit(1)
}
try? app.write(to: base.appendingPathComponent("app.js"), atomically: true, encoding: .utf8)
let clientDir = base.appendingPathComponent("client")
try? FileManager.default.createDirectory(at: clientDir, withIntermediateDirectories: true)
try? client.write(to: clientDir.appendingPathComponent("client.js"), atomically: true, encoding: .utf8)

func runClient(port: Int) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: realNode)
    process.arguments = ["client.js", String(port)]
    process.currentDirectoryURL = clientDir
    let out = Pipe()
    process.standardOutput = out
    process.standardError = Pipe()
    try? process.run()
    process.waitUntilExit()
    return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
}

// Ours serving.
let ourPort = freePort()
let source = try! String(contentsOf: base.appendingPathComponent("app.js"), encoding: .utf8)
let ourServer = Task.detached {
    let engine = NodeEngine(root: base, env: ["PATH": "/"])
    let result = await engine.run(source: source, path: "/app.js",
                                  argv: ["node", "/app.js", String(ourPort)], cwd: "/", stdin: "")
    if !result.err.isEmpty { FileHandle.standardError.write("engine stderr: \(result.err)\n".data(using: .utf8)!) }
}
try? await Task.sleep(nanoseconds: 1_500_000_000)
let fromOurs = runClient(port: ourPort)
ourServer.cancel()

// Real node serving the same app.
let realPort = freePort()
let realServer = Process()
realServer.executableURL = URL(fileURLWithPath: realNode)
realServer.arguments = ["app.js", String(realPort)]
realServer.currentDirectoryURL = base
realServer.standardOutput = Pipe()
realServer.standardError = Pipe()
try? realServer.run()
try? await Task.sleep(nanoseconds: 800_000_000)
let fromReal = runClient(port: realPort)
realServer.terminate()

if fromOurs == fromReal, !fromOurs.isEmpty {
    print("EXPRESS MATCH — real express on our engine answers node's client exactly as node does:")
    print(fromOurs)
} else {
    print("MISMATCH")
    print("---- ours ----\n\(fromOurs)---- real ----\n\(fromReal)")
    exit(1)
}
try? FileManager.default.removeItem(at: base)
