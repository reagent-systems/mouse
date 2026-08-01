import Foundation
let script = """
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
"""
let dir = FileManager.default.temporaryDirectory.appendingPathComponent("probe4-\(getpid())")
try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
let engine = NodeEngine(root: dir, env: [:])
let r = await engine.run(source: script, path: "/main.js", argv: ["node", "/main.js"], cwd: "/", stdin: "")
FileHandle.standardError.write("=== stdout: \(r.out.debugDescription) status \(r.status)\n".data(using: .utf8)!)
