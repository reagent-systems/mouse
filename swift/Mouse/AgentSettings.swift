import Foundation
import Security

/// The per-agent setup that has to survive a relaunch.
///
/// Every agent here needs something before it can answer: Claude Code needs an API key, Hermes
/// needs the address of the machine running its gateway. Asking again on every launch would make
/// the container unusable, which is why the current Hermes grew savable profiles in the first
/// place — this is that idea, one profile per agent.
///
/// A SECRET goes to the keychain, not to UserDefaults. An API key in a plist is readable by
/// anything that can read the container's files, including a backup of the phone.
@MainActor
@Observable
final class AgentSettings {
    static let shared = AgentSettings()

    private init() {}

    /// The saved value for an agent's setting, or "" when nothing is stored.
    func value(for agent: CodingAgent) -> String {
        guard let setting = agent.setting else { return "" }
        return setting.secret
            ? (Self.keychainRead(setting.name) ?? "")
            : (UserDefaults.standard.string(forKey: Self.key(agent, setting)) ?? "")
    }

    func set(_ value: String, for agent: CodingAgent) {
        guard let setting = agent.setting else { return }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if setting.secret {
            Self.keychainWrite(setting.name, trimmed)
        } else {
            UserDefaults.standard.set(trimmed, forKey: Self.key(agent, setting))
        }
        version += 1
    }

    func isSet(for agent: CodingAgent) -> Bool {
        agent.setting == nil || !value(for: agent).isEmpty
    }

    /// Bumped on every write so views observing this object redraw — the values themselves live
    /// in the keychain and UserDefaults, which `@Observable` cannot see into.
    private(set) var version = 0

    /// Where the agent's API server is, or "" for the documented default. Not a secret and not
    /// yet asked for in the UI: `hermes gateway` binds 127.0.0.1:8642 and the simulator can
    /// reach that, so the default is right until someone runs it elsewhere.
    func address(for agent: CodingAgent) -> String {
        UserDefaults.standard.string(forKey: "agent.\(agent.id).address") ?? ""
    }

    func setAddress(_ value: String, for agent: CodingAgent) {
        UserDefaults.standard.set(value.trimmingCharacters(in: .whitespaces),
                                  forKey: "agent.\(agent.id).address")
        version += 1
    }

    /// The shell line that puts the setting where the agent's own CLI looks for it. `export` is
    /// how a person would do it, and the agent is being driven the way a person would.
    func exportLine(for agent: CodingAgent) -> String? {
        guard let setting = agent.setting, setting.exported else { return nil }
        let value = self.value(for: agent)
        guard !value.isEmpty else { return nil }
        return "export \(setting.name)=\(value)"
    }

    private static func key(_ agent: CodingAgent, _ setting: CodingAgent.Setting) -> String {
        "agent.\(agent.id).\(setting.name)"
    }

    // MARK: - Keychain

    private static func query(_ name: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.reagentsystems.mouse.agent",
         kSecAttrAccount as String: name]
    }

    private static func keychainRead(_ name: String) -> String? {
        var request = query(name)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func keychainWrite(_ name: String, _ value: String) {
        SecItemDelete(query(name) as CFDictionary)
        guard !value.isEmpty else { return }
        var request = query(name)
        request[kSecValueData as String] = Data(value.utf8)
        // The phone is unlocked whenever the container is on screen, and this must not sync to
        // another device the user did not set up.
        request[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(request as CFDictionary, nil)
    }
}
