import Foundation

/// Lecture d'un flux « server-sent events ».
///
/// Séparé de HTTP.swift à dessein : `URLSession.bytes(for:)` n'existe que sur les plateformes
/// Apple, ce fichier est donc le seul de la couche réseau que l'outil de vérification hors Xcode
/// ne peut pas relire. Il est volontairement court.
extension HTTP {
    /// Livre le contenu de chaque ligne « data: », sans le préfixe, jusqu'à `[DONE]`.
    /// Aucune relance ici : l'appelant sait ce qu'il a déjà affiché et décide quoi faire.
    static func streamLines(
        _ request: URLRequest,
        provider: String,
        session: URLSession = HTTP.session
    ) async throws -> AsyncThrowingStream<String, Error> {
        let (bytes, response) = try await session.bytes(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw APIError(provider: provider, status: 0, message: "Réponse inattendue.", isTransport: true)
        }

        guard (200...299).contains(http.statusCode) else {
            var body = ""
            for try await line in bytes.lines {
                body += line
                if body.count > 2000 { break }
            }
            throw APIError(
                provider: provider,
                status: http.statusCode,
                message: errorMessage(from: Data(body.utf8)),
                retryAfter: Double(http.value(forHTTPHeaderField: "Retry-After") ?? "")
            )
        }

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        if !payload.isEmpty { continuation.yield(payload) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
