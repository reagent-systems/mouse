import Foundation
setvbuf(stdout, nil, _IONBF, 0)

// Does a response body arrive INCREMENTALLY through the URLSession path? An agent CLI streaming
// SSE from an HTTPS API depends on it, and `fetch` rides URLSession whatever the scheme — so a
// local HTTP server exercises the same transport without needing a certificate.
let base = FileManager.default.temporaryDirectory.appendingPathComponent("sse-\(getpid())")
try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
let port = 9500 + Int(getpid()) % 400

let server = Process()
server.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/python3")
server.arguments = ["server.py", String(port)]
server.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
server.standardOutput = Pipe()
server.standardError = Pipe()
try? server.run()
try? await Task.sleep(nanoseconds: 700_000_000)

let script = """
const started = Date.now();
async function main() {
  const response = await fetch('http://127.0.0.1:\(port)/stream');
  const reader = response.body.getReader();
  const arrivals = [];
  while (true) {
    const { value, done } = await reader.read();
    if (done) break;
    arrivals.push({ at: Date.now() - started, text: Buffer.from(value).toString().trim() });
  }
  // Three events sent half a second apart: if they arrived as they were sent, the gaps are
  // visible. If the transport buffered, every arrival shares one timestamp.
  console.log('arrivals:', arrivals.length);
  console.log('spread over time:', arrivals.length > 1 && (arrivals[arrivals.length - 1].at - arrivals[0].at) > 300);
  console.log('texts:', arrivals.map(a => a.text).join('|'));
}
main();
"""
let engine = NodeEngine(root: base, env: [:])
let result = await engine.run(source: script, path: "/main.js", argv: ["node", "/main.js"], cwd: "/", stdin: "")
server.terminate()
print("---- ours ----\n\(result.out)\(result.err.isEmpty ? "" : "stderr: \(result.err)")")
// This harness printed its output and asserted NOTHING, so it could only ever be read by hand.
// The property that matters is what streaming means: the chunks arrive SEPARATELY over time
// rather than in one lump at the end.
let text = result.out
let streamed = text.contains("arrivals: 3") && text.contains("spread over time: true")
    && text.contains("data: chunk0|data: chunk1|data: chunk2")
print(streamed ? "SSE MATCH — three chunks arrived separately, as they were sent"
               : "SSE MISMATCH — streaming did not arrive incrementally")
exit(streamed ? 0 : 1)
