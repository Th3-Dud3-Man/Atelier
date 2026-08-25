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
