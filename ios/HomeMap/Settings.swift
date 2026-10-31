import Foundation
import Security

/// Home Assistant address (UserDefaults) + access token (Keychain). Filled by scanning the pairing QR on the dashboard.
final class Settings: ObservableObject {
    @Published private(set) var url: String = UserDefaults.standard.string(forKey: "haURL") ?? ""
    @Published private(set) var token: String = Keychain.get("haToken") ?? ""

    var paired: Bool { !url.isEmpty && !token.isEmpty }
    /// Send debug logs to Home Assistant: what each scan did (see ScanLog), into HA's log while scanning + with the scan
    @Published var debugLogs: Bool = UserDefaults.standard.object(forKey: "debugLogs") as? Bool ?? true {
        didSet { UserDefaults.standard.set(debugLogs, forKey: "debugLogs") }
    }

    func save(url: String, token: String) {
        self.url = url.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(self.url, forKey: "haURL")
        Keychain.set("haToken", self.token)
    }

    func unpair() { save(url: "", token: "") }

    /// screenshots in the simulator: paired or not, without touching the real pairing
    func demo(paired: Bool) {
        url = paired ? "https://ha.example.com" : ""
        token = paired ? String(repeating: "x", count: 40) : ""
    }

    /// QR payload from the dashboard card: {"u": "https://…", "t": "<token>"}
    func pair(fromQR text: String) -> Bool {
        guard let d = text.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let u = o["u"] as? String, let t = o["t"] as? String,
              u.hasPrefix("https://"), t.count > 20 else { return false }
        save(url: u, token: t)
        return true
    }
}

enum Keychain {
    static func set(_ key: String, _ value: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: key]
        SecItemDelete(q as CFDictionary)
        guard !value.isEmpty else { return }
        var add = q
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ key: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: key,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
}
