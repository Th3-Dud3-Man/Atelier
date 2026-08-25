import Foundation
import Security

/// Les clés API sont rangées dans le trousseau de l'appareil, jamais dans le fichier JSON,
/// jamais dans le code, jamais dans le dépôt. `ThisDeviceOnly` empêche leur passage
/// dans une sauvegarde ou vers un autre appareil.
enum Keychain {
    enum Item: String, CaseIterable {
        case gemini = "fr.latelier.key.gemini"
        case perplexity = "fr.latelier.key.perplexity"
    }

    static func set(_ value: String, for item: Item) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            remove(item)
            return
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: item.rawValue,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: Data(trimmed.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            SecItemAdd(query.merging(attributes) { current, _ in current } as CFDictionary, nil)
        }
    }

    static func get(_ item: Item) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: item.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8)
        else { return "" }
        return value
    }

    static func remove(_ item: Item) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: item.rawValue,
        ]
        SecItemDelete(query as CFDictionary)
    }

    static func has(_ item: Item) -> Bool {
        !get(item).isEmpty
    }

    /// Version masquée pour l'affichage : « AIza••••••••7f2c ».
    static func masked(_ item: Item) -> String {
        let value = get(item)
        guard value.count > 8 else { return value.isEmpty ? "" : "••••" }
        return "\(value.prefix(4))••••••••\(value.suffix(4))"
    }
}
