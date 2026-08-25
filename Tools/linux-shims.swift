// Substituts utilisés UNIQUEMENT par Tools/typecheck.sh sur Linux.
// Ce fichier ne fait pas partie de l'app et n'est jamais compilé par Xcode :
// il redéclare les fonctions dont l'implémentation réelle s'appuie sur des API
// disponibles seulement sur les plateformes Apple, pour que le reste du code
// puisse quand même être relu par le compilateur.
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension HTTP {
    static func streamLines(
        _ request: URLRequest,
        provider: String,
        session: URLSession = HTTP.session
    ) async throws -> AsyncThrowingStream<String, Error> {
        fatalError("substitut de vérification")
    }
}

/// Le Keychain s'appuie sur le framework Security, absent hors plateformes Apple.
enum Keychain {
    enum Item: String, CaseIterable {
        case gemini = "fr.latelier.key.gemini"
        case perplexity = "fr.latelier.key.perplexity"
    }
    static func set(_ value: String, for item: Item) {}
    static func get(_ item: Item) -> String { "" }
    static func remove(_ item: Item) {}
    static func has(_ item: Item) -> Bool { false }
    static func masked(_ item: Item) -> String { "" }
}
