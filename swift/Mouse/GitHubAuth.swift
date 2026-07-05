import SwiftUI
import Security

/// GitHub sign-in for the container of kind 1 (`ContainerType.gitHubKind`), via the OAuth Device
/// Flow — the same GitHub App and flow the web client uses (`src/auth/GitHubAuth.ts`), so one
/// GitHub App serves every Mouse frontend. Sign-in state is app-global: every instance of the
/// GitHub container, in any ring, reflects the same session. Tokens live in the Keychain; only
/// the (non-secret) login handle is cached in UserDefaults for instant restore at launch.
@MainActor
@Observable
final class GitHubAuth {
    static let shared = GitHubAuth()

    /// Public identifier of the Mouse GitHub App (not a secret) — same as the web client's.
    private static let clientID = "Iv23liFfOa5cNvXvatNB"

    enum Phase {
        case signedOut
        case requestingCode
        /// Waiting for the user to enter `code` at `url` (GitHub's device-authorization page).
        case awaitingAuthorization(code: String, url: URL)
        case signedIn(login: String)
        case failed(String)
    }

    private(set) var phase: Phase

    private var signInTask: Task<Void, Never>?

    private init() {
        if Keychain.string(for: "access-token") != nil {
            // Instant restore from the cached handle; the session is validated in the background.
            phase = .signedIn(login: UserDefaults.standard.string(forKey: "githubLogin") ?? "…")
            Task { await validateSession() }
        } else {
            phase = .signedOut
        }
    }

    func signIn() {
        signInTask?.cancel()
        phase = .requestingCode
        signInTask = Task {
            do {
                let device = try await requestDeviceCode()
                guard !Task.isCancelled else { return }
                guard let url = URL(string: device.verificationUri) else {
                    throw AuthError("GitHub returned an unusable verification URL.")
                }
                phase = .awaitingAuthorization(code: device.userCode, url: url)
                let token = try await pollForToken(device)
                Keychain.set(token.accessToken, for: "access-token")
                if let refresh = token.refreshToken { Keychain.set(refresh, for: "refresh-token") }
                let user = try await fetchUser(token: token.accessToken)
                UserDefaults.standard.set(user.login, forKey: "githubLogin")
                phase = .signedIn(login: user.login)
            } catch is CancellationError {
                // Cancelled sign-ins fall back to whatever phase the canceller set.
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func cancelSignIn() {
        signInTask?.cancel()
        signInTask = nil
        phase = .signedOut
    }

    func signOut() {
        signInTask?.cancel()
        signInTask = nil
        Keychain.delete("access-token")
        Keychain.delete("refresh-token")
        UserDefaults.standard.removeObject(forKey: "githubLogin")
        phase = .signedOut
    }

    /// Confirm the stored token still works; refresh it once if GitHub rejects it, and sign out
    /// if that fails too. Network errors keep the cached session (offline shouldn't log you out).
    private func validateSession() async {
        guard let token = Keychain.string(for: "access-token") else { return }
        do {
            let user = try await fetchUser(token: token)
            UserDefaults.standard.set(user.login, forKey: "githubLogin")
            phase = .signedIn(login: user.login)
        } catch let error as HTTPError where error.status == 401 {
            if let refreshed = try? await refreshToken(),
               let user = try? await fetchUser(token: refreshed) {
                UserDefaults.standard.set(user.login, forKey: "githubLogin")
                phase = .signedIn(login: user.login)
            } else {
                signOut()
            }
        } catch {
            // Offline or transient — leave the cached session alone.
        }
    }

    // MARK: - Device flow plumbing

    private struct AuthError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    private struct HTTPError: Error {
        let status: Int
    }

    private struct DeviceCode: Decodable {
        let deviceCode: String
        let userCode: String
        let verificationUri: String
        let expiresIn: Int
        let interval: Int
    }

    private struct TokenResponse: Decodable {
        let accessToken: String?
        let refreshToken: String?
        let error: String?
        let interval: Int?
    }

    private struct Token {
        let accessToken: String
        let refreshToken: String?
    }

    private struct User: Decodable {
        let login: String
    }

    private func requestDeviceCode() async throws -> DeviceCode {
        try await postForm(
            to: "https://github.com/login/device/code",
            // GitHub App user tokens take their permissions from the app — no scope parameter.
            fields: ["client_id": Self.clientID]
        )
    }

    private func pollForToken(_ device: DeviceCode) async throws -> Token {
        var interval = max(device.interval, 5)
        let deadline = Date(timeIntervalSinceNow: TimeInterval(device.expiresIn))
        while Date() < deadline {
            try await Task.sleep(for: .seconds(interval))
            try Task.checkCancellation()
            let response: TokenResponse = try await postForm(
                to: "https://github.com/login/oauth/access_token",
                fields: [
                    "client_id": Self.clientID,
                    "device_code": device.deviceCode,
                    "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                ]
            )
            if let token = response.accessToken {
                return Token(accessToken: token, refreshToken: response.refreshToken)
            }
            switch response.error {
            case "authorization_pending":
                continue
            case "slow_down":
                interval = response.interval ?? (interval + 5)
            case "expired_token":
                throw AuthError("The code expired — start over.")
            case "access_denied":
                throw AuthError("Sign-in was declined on GitHub.")
            default:
                throw AuthError("GitHub said: \(response.error ?? "unknown error")")
            }
        }
        throw AuthError("The code expired — start over.")
    }

    private func refreshToken() async throws -> String {
        guard let refresh = Keychain.string(for: "refresh-token") else { throw HTTPError(status: 401) }
        let response: TokenResponse = try await postForm(
            to: "https://github.com/login/oauth/access_token",
            fields: [
                "client_id": Self.clientID,
                "refresh_token": refresh,
                "grant_type": "refresh_token",
            ]
        )
        guard let token = response.accessToken else { throw HTTPError(status: 401) }
        Keychain.set(token, for: "access-token")
        if let newRefresh = response.refreshToken { Keychain.set(newRefresh, for: "refresh-token") }
        return token
    }

    private func fetchUser(token: String) async throws -> User {
        var request = URLRequest(url: URL(string: "https://api.github.com/user")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw HTTPError(status: http.statusCode)
        }
        return try Self.decoder.decode(User.self, from: data)
    }

    private func postForm<T: Decodable>(to urlString: String, fields: [String: String]) async throws -> T {
        var request = URLRequest(url: URL(string: urlString)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = fields
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }
            .joined(separator: "&")
            .data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw HTTPError(status: http.statusCode)
        }
        return try Self.decoder.decode(T.self, from: data)
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()
}

/// Minimal Keychain wrapper for the GitHub tokens.
private enum Keychain {
    private static let service = "com.reagentsystems.mouse.swift.github"

    static func set(_ value: String, for account: String) {
        delete(account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8),
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func string(for account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// The GitHub container's face — rendered by `Panel` for kind 1 instead of a numeral.
struct GitHubSignInView: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 14) {
            switch GitHubAuth.shared.phase {
            case .signedOut:
                Text("GitHub")
                    .font(.custom(AppFont.asciiName, size: 28))
                Button { GitHubAuth.shared.signIn() } label: {
                    Text("Sign in")
                        .font(.custom(AppFont.asciiName, size: 16))
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(.white.opacity(0.16), in: Capsule())
                }

            case .requestingCode:
                ProgressView().tint(.white)
                Text("contacting GitHub…")
                    .font(.custom(AppFont.asciiName, size: 14))
                    .opacity(0.7)

            case .awaitingAuthorization(let code, let url):
                Text(code)
                    .font(.custom(AppFont.asciiName, size: 34))
                    .onTapGesture { UIPasteboard.general.string = code }
                Text("tap code to copy, then enter it at")
                    .font(.custom(AppFont.asciiName, size: 13))
                    .opacity(0.7)
                Button { openURL(url) } label: {
                    Text("github.com/login/device")
                        .font(.custom(AppFont.asciiName, size: 15))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(.white.opacity(0.16), in: Capsule())
                }
                Button { GitHubAuth.shared.cancelSignIn() } label: {
                    Text("cancel")
                        .font(.custom(AppFont.asciiName, size: 13))
                        .opacity(0.55)
                }

            case .signedIn(let login):
                Text("@\(login)")
                    .font(.custom(AppFont.asciiName, size: 26))
                Text("signed in with GitHub")
                    .font(.custom(AppFont.asciiName, size: 13))
                    .opacity(0.7)
                Button { GitHubAuth.shared.signOut() } label: {
                    Text("sign out")
                        .font(.custom(AppFont.asciiName, size: 13))
                        .opacity(0.55)
                }

            case .failed(let message):
                Text(message)
                    .font(.custom(AppFont.asciiName, size: 14))
                    .multilineTextAlignment(.center)
                    .opacity(0.85)
                    .padding(.horizontal, 24)
                Button { GitHubAuth.shared.signIn() } label: {
                    Text("try again")
                        .font(.custom(AppFont.asciiName, size: 15))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(.white.opacity(0.16), in: Capsule())
                }
            }
        }
        .foregroundStyle(.white)
    }
}
