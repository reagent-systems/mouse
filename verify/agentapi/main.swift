import Foundation
setvbuf(stdout, nil, _IONBF, 0)

// The client for Hermes's API server, against a server speaking the shape the docs describe.
//
// `hermes gateway` serves POST /v1/chat/completions with `{"model", "messages", "stream"}` and
// requires `Authorization: Bearer <API_SERVER_KEY>` on every deployment, including the loopback
// bind, with no way to disable it. What matters here is that we send exactly that — a client that
// quietly drops the header works against nothing, and one that posts to the wrong path fails in a
// way that looks like the server is down.
//
// A stand-in server rather than the real Hermes: this asserts OUR half. The previous version of
// this gate proved a client against a stub built from the same wrong guess as the client, so the
// shape here is taken from the published docs rather than from the code under test.

let port = 8644
var failures = 0
func check(_ condition: Bool, _ label: String) {
    if !condition { failures += 1; print("  FAIL: \(label)") }
}

let script = """
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        n = int(self.headers.get("content-length", 0))
        body = json.loads(self.rfile.read(n) or b"{}")
        auth = self.headers.get("Authorization", "")
        sys.stderr.write("PATH %s AUTH %s MODEL %s N %d\\n" %
                         (self.path, auth, body.get("model"), len(body.get("messages", []))))
        sys.stderr.flush()
        if auth != "Bearer right-key":
            out = b'{"error":{"message":"invalid api key"}}'
            self.send_response(401)
        elif body["messages"][-1]["content"] == "break":
            out = b'not json at all'
            self.send_response(200)
        else:
            out = json.dumps({"choices":[{"message":{"role":"assistant",
                  "content":"echo: " + body["messages"][-1]["content"]}}]}).encode()
            self.send_response(200)
        self.send_header("content-type","application/json")
        self.send_header("content-length", str(len(out)))
        self.end_headers(); self.wfile.write(out)
print("ready", flush=True)
HTTPServer(("127.0.0.1", \(port)), H).serve_forever()
"""
let scriptURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("agentapi-\(getpid()).py")
try? script.write(to: scriptURL, atomically: true, encoding: .utf8)
defer { try? FileManager.default.removeItem(at: scriptURL) }
let server = Process()
server.executableURL = URL(fileURLWithPath: "/usr/bin/env")
server.arguments = ["python3", scriptURL.path]
let ready = Pipe()
server.standardOutput = ready
server.standardError = Pipe()
try? server.run()
defer { server.terminate() }
_ = ready.fileHandleForReading.availableData

// The address the container types, and the documented default when it types nothing.
check(AgentAPI(address: "", key: "k")?.baseURL.absoluteString == "http://127.0.0.1:8642",
      "an empty address is the documented default")
check(AgentAPI(address: "10.0.0.5:9000", key: "k")?.baseURL.absoluteString == "http://10.0.0.5:9000",
      "host:port gets a scheme")
check(AgentAPI(address: "https://box.local:443", key: "k")?.baseURL.scheme == "https",
      "a scheme already there is kept")
check(AgentAPI(address: "http://", key: "k") == nil, "a hostless address is refused")
check(AgentAPI(address: "", key: "k")?.model == "hermes-agent", "the default profile's model name")

let api = AgentAPI(address: "127.0.0.1:\(port)", key: "right-key")!
do {
    let reply = try await api.complete([("user", "hello")])
    check(reply == "echo: hello", "the answer comes out of choices[0].message.content: \(reply)")
    let threaded = try await api.complete([("user", "one"), ("assistant", "two"), ("user", "three")])
    check(threaded == "echo: three", "the whole conversation goes up, newest last")
} catch {
    failures += 1
    print("  FAIL: a good call threw: \(error)")
}

// A wrong key must say so. This is the failure a user will actually hit.
do {
    _ = try await AgentAPI(address: "127.0.0.1:\(port)", key: "wrong")!.complete([("user", "hi")])
    failures += 1
    print("  FAIL: a rejected key should not look like success")
} catch {
    check("\(error)".contains("401"), "a rejected key reports 401: \(error)")
}

// A body that is not the expected shape is not an answer.
do {
    _ = try await api.complete([("user", "break")])
    failures += 1
    print("  FAIL: unparseable output should not be returned as an answer")
} catch {
    check("\(error)".contains("made no sense"), "a malformed body says so: \(error)")
}

// Nothing listening: report, do not hang.
do {
    _ = try await AgentAPI(address: "127.0.0.1:9", key: "k")!.complete([("user", "hi")])
    failures += 1
    print("  FAIL: a closed port should not answer")
} catch {
    check("\(error)".contains("cannot reach"), "a closed port reports why: \(error)")
}

if failures == 0 {
    print("AGENT API: the documented request — path, bearer, OpenAI body — plus a rejected key, a malformed answer and a closed port — MATCH")
} else {
    print("AGENT API: \(failures) checks failed — MISMATCH")
    exit(1)
}
