import Foundation
setvbuf(stdout, nil, _IONBF, 0)

// HTTP/2 over cleartext, with REAL NODE'S CLIENT as the peer — which is the only test that
// counts for a protocol: node's http2 client speaks nghttp2, so every frame, every HPACK block
// and every window update has to be right or it hangs up rather than negotiating.
//
// The server runs on this engine, on our own TCP sockets, with the HPACK from the last
// boundary. What is asserted is what the client SEES: status, headers, body, several requests
// multiplexed over one connection, a request body read on the server side, and a PING answered.

let realNode = "/Users/thyfriendlyfox/.local/bin/node"
let base = FileManager.default.temporaryDirectory.appendingPathComponent("http2-\(getpid())")
try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

let server = """
const http2 = require('http2');
const server = http2.createServer();
server.on('stream', (stream, headers) => {
  const path = headers[':path'];
  if (path === '/echo') {
    const chunks = [];
    stream.on('data', (chunk) => chunks.push(chunk));
    stream.on('end', () => {
      const body = Buffer.concat(chunks).toString();
      stream.respond({ ':status': 200, 'content-type': 'text/plain', 'x-echoed': String(body.length) });
      stream.end('echo:' + body);
    });
    return;
  }
  if (path === '/headers') {
    stream.respond({ ':status': 201, 'x-one': 'first', 'x-two': 'second', 'content-type': 'application/json' });
    stream.end(JSON.stringify({ method: headers[':method'], scheme: headers[':scheme'],
                                custom: headers['x-custom'] || null }));
    return;
  }
  if (path === '/big') {
    stream.respond({ ':status': 200 });
    stream.end('x'.repeat(40000));
    return;
  }
  stream.respond({ ':status': 404 });
  stream.end('not found');
});
server.listen(5411, '127.0.0.1', () => console.log('listening'));
"""

let client = """
const http2 = require('http2');
const session = http2.connect('http://127.0.0.1:5411');
const results = [];
function request(path, options, body) {
  return new Promise((resolve, reject) => {
    const stream = session.request(Object.assign({ ':path': path }, options || {}));
    let data = '';
    let head = null;
    stream.on('response', (headers) => { head = headers; });
    stream.setEncoding('utf8');
    stream.on('data', (chunk) => { data += chunk; });
    stream.on('end', () => resolve({ head, data }));
    stream.on('error', reject);
    if (body !== undefined) stream.end(body); else stream.end();
  });
}
(async () => {
  const plain = await request('/headers', { ':method': 'GET', 'x-custom': 'sent' });
  results.push('status ' + plain.head[':status']);
  results.push('headers ' + [plain.head['x-one'], plain.head['x-two'], plain.head['content-type']].join(','));
  results.push('body ' + plain.data);

  const echoed = await request('/echo', { ':method': 'POST' }, 'a request body');
  results.push('echo ' + echoed.data + ' | x-echoed=' + echoed.head['x-echoed']);

  const missing = await request('/nowhere');
  results.push('missing ' + missing.head[':status'] + ' ' + missing.data);

  // Several at once over ONE connection: multiplexing is the whole point of the protocol.
  const many = await Promise.all([request('/headers'), request('/echo', { ':method': 'POST' }, 'x'), request('/headers')]);
  results.push('multiplexed ' + many.map((r) => r.head[':status']).join(','));

  // A body larger than one frame, so the 16 KiB cap and the flow-control credit both matter.
  const big = await request('/big');
  results.push('big ' + big.data.length + ' ' + (big.data === 'x'.repeat(40000)));

  await new Promise((resolve) => session.ping((error, duration) => {
    results.push('ping ' + (error ? 'FAILED' : 'answered'));
    resolve();
  }));

  console.log(results.join('\\n'));
  session.close();
})().catch((error) => { console.log('CLIENT FAILED: ' + error.message); session.close(); });
"""

// And the mirror: real node SERVES, this engine's client asks. A protocol has two halves and
// each is only proven against something that did not come from here.
let nodeServer = """
const http2 = require('http2');
const server = http2.createServer();
server.on('stream', (stream, headers) => {
  const path = headers[':path'];
  if (path === '/echo') {
    const chunks = [];
    stream.on('data', (chunk) => chunks.push(chunk));
    stream.on('end', () => {
      stream.respond({ ':status': 200, 'x-echoed': String(Buffer.concat(chunks).length) });
      stream.end('echo:' + Buffer.concat(chunks).toString());
    });
    return;
  }
  if (path === '/headers') {
    stream.respond({ ':status': 201, 'x-one': 'first', 'content-type': 'application/json' });
    stream.end(JSON.stringify({ method: headers[':method'], scheme: headers[':scheme'],
                                authority: headers[':authority'], custom: headers['x-custom'] || null }));
    return;
  }
  if (path === '/big') { stream.respond({ ':status': 200 }); stream.end('y'.repeat(40000)); return; }
  stream.respond({ ':status': 404 });
  stream.end('nope');
});
server.listen(5413, '127.0.0.1', () => console.log('listening'));
"""
let ourClient = """
const http2 = require('http2');
const session = http2.connect('http://127.0.0.1:5413');
const results = [];
function request(path, options, body) {
  return new Promise((resolve, reject) => {
    const stream = session.request(Object.assign({ ':path': path }, options || {}));
    let head = null, data = '';
    stream.on('response', (headers) => { head = headers; });
    stream.setEncoding('utf8');
    stream.on('data', (chunk) => { data += chunk; });
    stream.on('end', () => resolve({ head, data }));
    stream.on('error', reject);
    if (body !== undefined) stream.end(body); else stream.end();
  });
}
(async () => {
  const plain = await request('/headers', { ':method': 'GET', 'x-custom': 'sent' });
  results.push('status ' + plain.head[':status']);
  results.push('headers ' + [plain.head['x-one'], plain.head['content-type']].join(','));
  results.push('body ' + plain.data);
  const echoed = await request('/echo', { ':method': 'POST' }, 'from our client');
  results.push('echo ' + echoed.data + ' | x-echoed=' + echoed.head['x-echoed']);
  const missing = await request('/nowhere');
  results.push('missing ' + missing.head[':status'] + ' ' + missing.data);
  const many = await Promise.all([request('/headers'), request('/echo', { ':method': 'POST' }, 'y'), request('/headers')]);
  results.push('multiplexed ' + many.map((r) => r.head[':status']).join(','));
  const big = await request('/big');
  results.push('big ' + big.data.length + ' ' + (big.data === 'y'.repeat(40000)));
  await new Promise((resolve) => session.ping(() => { results.push('ping answered'); resolve(); }));
  console.log(results.join('\\n'));
  session.close();
})().catch((error) => { console.log('OUR CLIENT FAILED: ' + (error && error.message)); session.close(); });
"""

try? server.write(to: base.appendingPathComponent("server.cjs"), atomically: true, encoding: .utf8)
try? client.write(to: base.appendingPathComponent("client.cjs"), atomically: true, encoding: .utf8)

// Our engine serves; real node asks.
let engine = NodeEngine(root: base, env: ["PATH": "/"])
let serving = Task { await engine.run(source: server, path: "/server.cjs",
                                      argv: ["node", "/server.cjs"], cwd: "/", stdin: "") }
try? await Task.sleep(nanoseconds: 1_500_000_000)

let process = Process()
process.executableURL = URL(fileURLWithPath: realNode)
process.arguments = ["client.cjs"]
process.currentDirectoryURL = base
let out = Pipe(), err = Pipe()
process.standardOutput = out
process.standardError = err
try? process.run()
let clientText = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
let clientProblems = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
process.waitUntilExit()
serving.cancel()
_ = await serving.value

print("---- what node's client saw ----\n\(clientText)")
if !clientProblems.isEmpty { print("client stderr: \(clientProblems.prefix(500))") }

let expected = [
    "status 201",
    "headers first,second,application/json",
    #"body {"method":"GET","scheme":"http","custom":"sent"}"#,
    "echo echo:a request body | x-echoed=14",
    "missing 404 not found",
    "multiplexed 201,200,201",
    "big 40000 true",
    "ping answered",
]
let lines = clientText.components(separatedBy: "\n").filter { !$0.isEmpty }
// ---- the other direction ----
try? nodeServer.write(to: base.appendingPathComponent("nodeserver.cjs"), atomically: true, encoding: .utf8)
let serverProcess = Process()
serverProcess.executableURL = URL(fileURLWithPath: realNode)
serverProcess.arguments = ["nodeserver.cjs"]
serverProcess.currentDirectoryURL = base
serverProcess.standardOutput = Pipe()
serverProcess.standardError = Pipe()
try? serverProcess.run()
try? await Task.sleep(nanoseconds: 1_200_000_000)

let clientEngine = NodeEngine(root: base, env: ["PATH": "/"])
let asked = await clientEngine.run(source: ourClient, path: "/ourclient.cjs",
                                   argv: ["node", "/ourclient.cjs"], cwd: "/", stdin: "")
serverProcess.terminate()
print("---- what our client saw ----\n\(asked.out)")
if !asked.err.isEmpty { print("our client stderr: \(asked.err.prefix(500))") }

let expectedFromNode = [
    "status 201",
    "headers first,application/json",
    #"body {"method":"GET","scheme":"http","authority":"127.0.0.1:5413","custom":"sent"}"#,
    "echo echo:from our client | x-echoed=15",
    "missing 404 nope",
    "multiplexed 201,200,201",
    "big 40000 true",
    "ping answered",
]
let ourLines = asked.out.components(separatedBy: "\n").filter { !$0.isEmpty }

if lines == expected, ourLines == expectedFromNode {
    print("HTTP/2 MATCH — both halves against real node: its client made \(expected.count) "
          + "exchanges with this engine's server, and this engine's client made "
          + "\(expectedFromNode.count) with its server — headers, bodies both ways, 404, three "
          + "streams multiplexed on one connection, 40 KB across frames, and PING")
} else {
    for (index, want) in expectedFromNode.enumerated() {
        let got = index < ourLines.count ? ourLines[index] : "(missing)"
        if got != want { print("OUR CLIENT DIFFERS\n  ours: \(got)\n  want: \(want)") }
    }
    for (index, want) in expected.enumerated() {
        let got = index < lines.count ? lines[index] : "(missing)"
        if got != want { print("DIFFERS\n  ours: \(got)\n  want: \(want)") }
    }
    print("MISMATCH: http/2")
    exit(1)
}
try? FileManager.default.removeItem(at: base)
