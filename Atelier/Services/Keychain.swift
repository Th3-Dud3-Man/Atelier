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

    /// Range une clé et **dit si le trousseau l'a acceptée**. Un enregistrement silencieusement
    /// refusé — appareil encore verrouillé après un redémarrage, entrée en double — donnerait
    /// un écran de réglages affirmant « clé enregistrée » alors que la recherche échouera.
    @discardableResult
    static func set(_ value: String, for item: Item) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            remove(item)
            return true
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: item.rawValue,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: Data(trimmed.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updated = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updated == errSecSuccess { return true }

        let added = SecItemAdd(query.merging(attributes) { current, _ in current } as CFDictionary, nil)
        if added == errSecSuccess { return true }
        // Une entrée existe déjà mais la mise à jour ne l'a pas trouvée : on repart de zéro.
        if added == errSecDuplicateItem {
            SecItemDelete(query as CFDictionary)
            let retried = SecItemAdd(
                query.merging(attributes) { current, _ in current } as CFDictionary, nil
            )
            return retried == errSecSuccess
        }
        return false
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
