import Foundation

/// A client for Hermes Agent's API server — and for anything else OpenAI-shaped.
///
/// `hermes gateway` serves `POST /v1/chat/completions` on `http://127.0.0.1:8642`, taking
/// `{"model", "messages", "stream"}` and answering in `choices[0].message.content`, with
/// `Authorization: Bearer <API_SERVER_KEY>` required on every deployment including the loopback
/// bind. That is the documented way a custom client talks to Hermes. The TUI gateway this file
/// used to speak to is an internal detail, and the messaging gateway only polls named platforms
/// outward, so neither was ever an interface for this app to call.
///
/// Being OpenAI-shaped, none of this is Hermes-specific: any agent serving that endpoint is one
/// catalog entry away.
struct AgentAPI: Sendable {
    /// Where the server is. `hermes gateway` binds loopback, which the SIMULATOR can reach
    /// because it shares the Mac's network stack — a real phone needs the server bound wider or
    /// reached across the LAN.
    let baseURL: URL
    /// `API_SERVER_KEY`. Not optional: Hermes requires bearer auth on every deployment and will
    /// not let it be disabled, so a missing key is a configuration error, not an anonymous call.
    let key: String
    /// Defaults to the profile name, or `hermes-agent` for the default profile.
    let model: String

    /// `host:port` as typed into the container, with the documented default filled in.
    init?(address: String, key: String, model: String = "hermes-agent") {
        let trimmed = address.trimmingCharacters(in: .whitespaces)
        let text = trimmed.isEmpty ? "127.0.0.1:8642" : trimmed
        let withScheme = text.contains("://") ? text : "http://" + text
        guard let url = URL(string: withScheme), url.host != nil else { return nil }
        baseURL = url
        self.key = key
        self.model = model
    }

    enum Failure: Error, CustomStringConvertible {
        case http(Int, String)
        case malformed(String)
        case unreachable(String)

        var description: String {
            switch self {
            // 401 is the common one and is its own explanation: the key is wrong or absent.
            case .http(let code, let body):
                return "the agent answered \(code)" + (body.isEmpty ? "" : ": \(body)")
            case .malformed(let what): return "the agent's answer made no sense: \(what)"
            case .unreachable(let why): return "cannot reach the agent: \(why)"
            }
        }
    }

    /// One turn. The whole conversation goes up each time, which is what the endpoint expects —
    /// it is stateless per request, like every OpenAI-shaped API.
    func complete(_ conversation: [(role: String, content: String)]) async throws -> String {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 180
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "messages": conversation.map { ["role": $0.role, "content": $0.content] },
            "stream": false,
        ])

        let data: Data, response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw Failure.unreachable(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw Failure.http(http.statusCode,
                               String(decoding: data.prefix(300), as: UTF8.self)
                                   .trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw Failure.malformed(String(decoding: data.prefix(300), as: UTF8.self))
        }
        return content
    }
}
