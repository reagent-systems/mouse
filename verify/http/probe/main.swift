import Foundation
func mark(_ s: String) { FileHandle.standardError.write("MARK \(s)\n".data(using: .utf8)!) }
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
let rawClient = """
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
  console.error('SHAPE ' + (i-1) + ' ' + JSON.stringify(body.split('\\r\\n')[0]));
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
let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hp3-\(getpid())")
try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
let cdir = dir.appendingPathComponent("client")
try? FileManager.default.createDirectory(at: cdir, withIntermediateDirectories: true)
let port = 9911 + Int(getpid()) % 80
let task = Task.detached {
    let engine = NodeEngine(root: dir, env: [:])
    let r = await engine.run(source: serverScript, path: "/main.js", argv: ["node", "/main.js", String(port)], cwd: "/", stdin: "")
    mark("engine returned status=\(r.status) err=\(r.err)")
}
try? await Task.sleep(nanoseconds: 600_000_000)
try? rawClient.write(to: cdir.appendingPathComponent("raw.js"), atomically: true, encoding: .utf8)
let p = Process()
p.executableURL = URL(fileURLWithPath: "/Users/thyfriendlyfox/.local/bin/node")
p.arguments = ["raw.js", String(port)]
p.currentDirectoryURL = cdir
let out = Pipe(); p.standardOutput = out
try? p.run()
mark("waiting")
p.waitUntilExit()
mark("client exited")
print(String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
task.cancel()
