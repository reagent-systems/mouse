import Foundation
import Network

/// A client of Hermes's TUI gateway.
///
/// Hermes is a terminal application, and this container is not a terminal — but it does not have
/// to be. `tui_gateway` is how Hermes already talks to front-ends that are not terminals, and its
/// Telegram bot is one of them: the agent runs on a machine, and the chat surface is a client.
/// That is the only shape available here anyway, because the CPython build on this device has no
/// pip and Hermes cannot be installed locally at all.
///
/// The protocol is newline-delimited JSON, one object per line: `{"id": n, "command": "…"}` out,
/// objects back carrying the same `id`. Anything without our id is an unsolicited event — Hermes
/// streams those while it works — and is handed over as it arrives.
actor HermesGateway {
    struct Address {
        let host: String
        let port: UInt16

        /// `host:port`, the way it is typed into the container's setup field. A bare host gets
        /// the gateway's default port rather than being refused over a missing colon.
        init?(_ text: String) {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }
            let parts = trimmed.split(separator: ":", maxSplits: 1)
            host = String(parts[0])
            guard !host.isEmpty else { return nil }
            if parts.count == 2 {
                guard let parsed = UInt16(parts[1]) else { return nil }
                port = parsed
            } else {
                port = 8765
            }
        }
    }

    enum Failure: Error, CustomStringConvertible {
        case unreachable(String)
        case closed
        case malformed(String)

        var description: String {
            switch self {
            case .unreachable(let why): return "gateway unreachable: \(why)"
            case .closed: return "the gateway closed the connection"
            case .malformed(let line): return "the gateway sent something that is not JSON: \(line)"
            }
        }
    }

    private let address: Address
    private var connection: NWConnection?
    private var nextID = 1
    /// Bytes read but not yet split into lines. A read returns whatever arrived, which is not
    /// necessarily a whole line and can be several.
    private var pending = Data()

    init(address: Address) {
        self.address = address
    }

    func close() {
        connection?.cancel()
        connection = nil
        pending = Data()
    }

    /// Send one command and collect everything the gateway says until it answers with our id.
    /// Returns the lines in order — the streamed events first, the reply last.
    func ask(_ command: String, timeout: TimeInterval = 120) async throws -> [[String: Any]] {
        let connection = try await connect()
        let id = nextID
        nextID += 1
        let request = try JSONSerialization.data(withJSONObject: ["id": id, "command": command])
        try await write(connection, request + Data("\n".utf8))

        var collected: [[String: Any]] = []
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let line = try await readLine(connection)
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw Failure.malformed(line)
            }
            collected.append(object)
            // Ours is the one carrying our id. Everything before it is Hermes narrating.
            if let answered = object["id"] as? Int, answered == id { return collected }
        }
        return collected
    }

    // MARK: - Connection

    private func connect() async throws -> NWConnection {
        if let connection, connection.state == .ready { return connection }
        self.connection?.cancel()
        let endpoint = NWEndpoint.Host(address.host)
        guard let port = NWEndpoint.Port(rawValue: address.port) else {
            throw Failure.unreachable("port \(address.port)")
        }
        let connection = NWConnection(host: endpoint, port: port, using: .tcp)
        self.connection = connection
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var resumed = false
            connection.stateUpdateHandler = { state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    continuation.resume()
                case .failed(let error):
                    resumed = true
                    continuation.resume(throwing: Failure.unreachable(error.localizedDescription))
                // `.waiting` is Network.framework saying "refused, but I will keep trying" — it
                // retries a closed port forever and never reaches `.failed`. For a gateway the
                // user just typed an address for, the first refusal IS the answer; retrying in
                // silence is the hang, not the resilience.
                case .waiting(let error):
                    resumed = true
                    continuation.resume(throwing: Failure.unreachable(error.localizedDescription))
                case .cancelled:
                    resumed = true
                    continuation.resume(throwing: Failure.closed)
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
        }
        return connection
    }

    private func write(_ connection: NWConnection, _ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: Failure.unreachable(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    /// One line, reading more from the socket only when the buffer does not already hold one.
    private func readLine(_ connection: NWConnection) async throws -> String {
        while true {
            if let newline = pending.firstIndex(of: 0x0a) {
                let line = pending[pending.startIndex..<newline]
                pending.removeSubrange(pending.startIndex...newline)
                let text = String(decoding: line, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty { continue }
                return text
            }
            let chunk = try await receive(connection)
            guard !chunk.isEmpty else { throw Failure.closed }
            pending.append(chunk)
        }
    }

    private func receive(_ connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, complete, error in
                if let error {
                    continuation.resume(throwing: Failure.unreachable(error.localizedDescription))
                } else if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if complete {
                    continuation.resume(throwing: Failure.closed)
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }
}
