import Foundation
setvbuf(stdout, nil, _IONBF, 0)

// The client of Hermes's TUI gateway, against a STUB that speaks its protocol.
//
// Hermes cannot be installed on the device — the CPython build there has no pip — so the only
// shape available is the one its Telegram bot already uses: Hermes runs on a machine and the chat
// surface is a client of `tui_gateway`. That protocol is newline-delimited JSON, `{"id", "command"}`
// out and objects carrying the same id back, with unsolicited events streamed in between.
//
// A stub rather than the real Hermes: this asserts the CLIENT, and pulling in someone's Python
// environment and model credentials to prove a socket reads lines would test neither reliably.
// The stub is written to speak exactly what `tui_gateway/server.py` writes.

let port: UInt16 = 8791
let stub = """
import json, socket, threading
srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", \(port)))
srv.listen(4)
print("ready", flush=True)
def serve(conn):
    buf = b""
    while True:
        chunk = conn.recv(65536)
        if not chunk: break
        buf += chunk
        while b"\\n" in buf:
            line, buf = buf.split(b"\\n", 1)
            if not line.strip(): continue
            req = json.loads(line)
            # Hermes narrates while it works: events with no id, then the answer with the id.
            conn.sendall((json.dumps({"type": "status", "text": "thinking"}) + "\\n").encode())
            # Deliberately split across two writes so the client must reassemble a line.
            reply = json.dumps({"id": req["id"], "type": "send",
                                "message": "you said: " + req["command"]}) + "\\n"
            half = len(reply) // 2
            conn.sendall(reply[:half].encode()); conn.sendall(reply[half:].encode())
conn, _ = srv.accept()
serve(conn)
"""
let scriptURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("hermes-stub-\(getpid()).py")
try? stub.write(to: scriptURL, atomically: true, encoding: .utf8)
defer { try? FileManager.default.removeItem(at: scriptURL) }

let python = Process()
python.executableURL = URL(fileURLWithPath: "/usr/bin/env")
python.arguments = ["python3", scriptURL.path]
let ready = Pipe()
python.standardOutput = ready
python.standardError = Pipe()
try? python.run()
defer { python.terminate() }
// Wait for the stub to say it is listening rather than sleeping and hoping.
_ = ready.fileHandleForReading.availableData

var failures = 0
func check(_ condition: Bool, _ label: String) {
    if !condition { failures += 1; print("  FAIL: \(label)") }
}

check(HermesGateway.Address("127.0.0.1:\(port)")?.port == port, "host:port parses")
check(HermesGateway.Address("hermes.local")?.port == 8765, "a bare host takes the default port")
check(HermesGateway.Address("")?.host == nil, "empty is not an address")
check(HermesGateway.Address("host:notaport") == nil, "a bad port is refused, not guessed")

guard let address = HermesGateway.Address("127.0.0.1:\(port)") else {
    print("HERMES GATEWAY: could not build the address — MISMATCH"); exit(1)
}
let gateway = HermesGateway(address: address)
do {
    let objects = try await gateway.ask("hello there", timeout: 20)
    check(objects.count == 2, "the streamed event and the answer both arrive (\(objects.count))")
    check(objects.first?["type"] as? String == "status", "the event comes first")
    check(objects.last?["message"] as? String == "you said: hello there",
          "the answer is reassembled from two writes: \(objects.last?["message"] as? String ?? "nil")")
    check(objects.last?["id"] as? Int == 1, "the answer carries the id it was asked with")

    let second = try await gateway.ask("again", timeout: 20)
    check(second.last?["id"] as? Int == 2, "the id advances on the same connection")
    check(second.last?["message"] as? String == "you said: again", "the second answer is its own")
} catch {
    failures += 1
    print("  FAIL: ask threw: \(error)")
}
await gateway.close()

// An address nobody is listening on must fail, and say so, rather than hang.
if let dead = HermesGateway.Address("127.0.0.1:9") {
    do {
        _ = try await HermesGateway(address: dead).ask("anyone", timeout: 5)
        failures += 1
        print("  FAIL: a closed port should not answer")
    } catch {
        check("\(error)".contains("unreachable") || "\(error)".contains("closed"),
              "a closed port reports why: \(error)")
    }
}

if failures == 0 {
    print("HERMES GATEWAY: the client speaks tui_gateway's line protocol — streamed events, split writes, advancing ids, a refused address — MATCH")
} else {
    print("HERMES GATEWAY: \(failures) checks failed — MISMATCH")
    exit(1)
}
