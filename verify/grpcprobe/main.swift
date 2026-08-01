import Foundation
setvbuf(stdout, nil, _IONBF, 0)

// gRPC is the hardest thing that can be asked of an HTTP/2 stack, because it uses the parts of
// the protocol nothing else does: trailers carry the status, the response headers say 200 long
// before the call has succeeded or failed, and a server-streaming call is a single stream that
// stays open across many DATA frames. @grpc/grpc-js is pure JavaScript on top of node's http2,
// so it runs here — and every frame it emits is read by real nghttp2 on the other side of the
// socket, in both directions.
let realNode = "/Users/thyfriendlyfox/.local/bin/node"
let base = FileManager.default.temporaryDirectory.appendingPathComponent("grpc-\(getpid())")
try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
_ = try await PackageManager.install(requirements: ["@grpc/grpc-js": "^1.12.0"], into: base)

// A service defined by hand: no proto-loader, no .proto file, so what is under test is the
// transport and not a code generator.
let service = """
const grpc = require('@grpc/grpc-js');
const json = {
  requestSerialize: (value) => Buffer.from(JSON.stringify(value)),
  requestDeserialize: (bytes) => JSON.parse(bytes.toString()),
  responseSerialize: (value) => Buffer.from(JSON.stringify(value)),
  responseDeserialize: (bytes) => JSON.parse(bytes.toString()),
};
const service = {
  echo: Object.assign({ path: '/probe.Probe/Echo', requestStream: false, responseStream: false }, json),
  countdown: Object.assign({ path: '/probe.Probe/Countdown', requestStream: false, responseStream: true }, json),
  fail: Object.assign({ path: '/probe.Probe/Fail', requestStream: false, responseStream: false }, json),
};
"""

let server = service + """
const server = new grpc.Server();
server.addService(service, {
  echo: (call, callback) => {
    const initial = new grpc.Metadata();
    initial.set('x-probe', 'seen');
    call.sendMetadata(initial);
    callback(null, { said: call.request.say, at: 'server' });
  },
  countdown: (call) => {
    for (let n = Number(call.request.from); n > 0; n -= 1) call.write({ n: n });
    call.end();
  },
  fail: (call, callback) => {
    callback({ code: grpc.status.INVALID_ARGUMENT, details: 'nope: bad input' });
  },
});
server.bindAsync(process.argv[2], grpc.ServerCredentials.createInsecure(), (error, port) => {
  if (error) { console.log('bind failed: ' + error.message); return; }
  console.log('bound ' + port);
});
"""

let client = service + """
const Client = grpc.makeGenericClientConstructor(service, 'Probe');
const client = new Client(process.argv[2], grpc.credentials.createInsecure());
const said = [];
function done() {
  console.log(said.join('\\n'));
  client.close();
  process.exit(0);
}
const call = client.echo({ say: 'hello grpc' }, (error, response) => {
  said.push(error ? ('unary failed ' + error.code) : ('unary ' + JSON.stringify(response)));
  const stream = client.countdown({ from: 3 });
  const seen = [];
  stream.on('data', (item) => seen.push(item.n));
  stream.on('end', () => {
    said.push('stream ' + seen.join(','));
    client.fail({}, (failure) => {
      said.push('error ' + (failure ? failure.code + ' ' + failure.details : 'none'));
      done();
    });
  });
  stream.on('error', (streamError) => { said.push('stream failed ' + streamError.code); done(); });
});
call.on('metadata', (metadata) => said.push('metadata x-probe=' + metadata.get('x-probe').join(',')));
setTimeout(() => { said.push('timed out'); done(); }, 20000);
"""

try? server.write(to: base.appendingPathComponent("server.cjs"), atomically: true, encoding: .utf8)
try? client.write(to: base.appendingPathComponent("client.cjs"), atomically: true, encoding: .utf8)

let expected = [
    "metadata x-probe=seen",
    #"unary {"said":"hello grpc","at":"server"}"#,
    "stream 3,2,1",
    "error 3 nope: bad input",
]

func nodeRun(_ file: String, _ address: String) -> Process {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: realNode)
    process.arguments = [file, address]
    process.currentDirectoryURL = base
    return process
}

// ---- our engine serves, real node calls -------------------------------------------------
let engine = NodeEngine(root: base, env: ["PATH": "/", "HOME": "/"])
let serving = Task {
    await engine.run(source: server, path: "/server.cjs",
                     argv: ["node", "/server.cjs", "127.0.0.1:5431"], cwd: "/", stdin: "")
}
try? await Task.sleep(nanoseconds: 2_000_000_000)

let nodeClient = nodeRun("client.cjs", "127.0.0.1:5431")
let clientOut = Pipe(), clientErr = Pipe()
nodeClient.standardOutput = clientOut
nodeClient.standardError = clientErr
try? nodeClient.run()
let nodeSaw = String(decoding: clientOut.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
let nodeClientProblems = String(decoding: clientErr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
nodeClient.waitUntilExit()
serving.cancel()
let servedResult = await serving.value

// ---- real node serves, our engine calls -------------------------------------------------
let nodeServer = nodeRun("server.cjs", "127.0.0.1:5432")
nodeServer.standardOutput = Pipe()
nodeServer.standardError = Pipe()
try? nodeServer.run()
try? await Task.sleep(nanoseconds: 1_500_000_000)

let clientEngine = NodeEngine(root: base, env: ["PATH": "/", "HOME": "/"])
let asked = await clientEngine.run(source: client, path: "/client.cjs",
                                   argv: ["node", "/client.cjs", "127.0.0.1:5432"], cwd: "/", stdin: "")
nodeServer.terminate()

let nodeLines = nodeSaw.components(separatedBy: "\n").filter { !$0.isEmpty }
let ourLines = asked.out.components(separatedBy: "\n").filter { !$0.isEmpty }

if nodeLines == expected, ourLines == expected {
    print("gRPC MATCH — @grpc/grpc-js runs on this engine as both peers, and every frame "
          + "crosses to real nghttp2: node's client made \(expected.count) exchanges against "
          + "this engine's server, and this engine's client made \(expected.count) against "
          + "node's — unary, initial metadata, a server-streaming call over one stream, and a "
          + "rejected call whose status arrives in the trailers")
} else {
    print("---- node's client, against our server ----\n\(nodeSaw)")
    if !nodeClientProblems.isEmpty { print("stderr: \(nodeClientProblems.prefix(900))") }
    print("---- our server said ----\n\(servedResult.out)\n\(servedResult.err.prefix(1500))")
    print("---- our client, against node's server ----\n\(asked.out)")
    if !asked.err.isEmpty { print("stderr: \(asked.err.prefix(700))") }
    for (index, want) in expected.enumerated() {
        let theirs = index < nodeLines.count ? nodeLines[index] : "(missing)"
        let ours = index < ourLines.count ? ourLines[index] : "(missing)"
        if theirs != want { print("NODE CLIENT DIFFERS\n  saw:  \(theirs)\n  want: \(want)") }
        if ours != want { print("OUR CLIENT DIFFERS\n  saw:  \(ours)\n  want: \(want)") }
    }
    print("MISMATCH: gRPC")
    try? FileManager.default.removeItem(at: base)
    exit(1)
}
try? FileManager.default.removeItem(at: base)
