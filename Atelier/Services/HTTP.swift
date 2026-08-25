import Foundation

/// Erreur réseau typée, avec un message montrable tel quel à l'écran.
struct APIError: LocalizedError, Sendable {
    var provider: String
    var status: Int
    var message: String
    var retryAfter: Double?
    /// Vrai quand la requête n'a jamais atteint le serveur (réseau coupé, DNS, TLS).
    var isTransport: Bool = false

    var retryable: Bool {
        status == 429 || (500...599).contains(status) || isTransport
    }

    /// Message humain : jamais de JSON brut ni de code technique nu dans l'interface.
    var errorDescription: String? {
        switch status {
        case 401, 403:
            "\(provider) refuse la clé (erreur \(status)). Vérifiez-la dans les réglages."
        case 429:
            if let retryAfter {
                "\(provider) limite le nombre d'appels. Réessayez dans \(Int(retryAfter.rounded(.up))) s."
            } else {
                "\(provider) limite le nombre d'appels (erreur 429). Réessayez dans un instant."
            }
        case 400:
            "\(provider) a refusé la requête : \(message)"
        case 404:
            "\(provider) : ressource introuvable (erreur 404)."
        case 500...599:
            "\(provider) ne répond pas correctement (erreur \(status)). Réessayez dans un moment."
        default:
            isTransport
                ? "\(provider) est injoignable. Vérifiez votre connexion, puis réessayez."
                : "\(provider) : \(message)"
        }
    }
}

enum HTTP {
    /// Session dédiée : pas de cache disque pour des réponses d'IA, et des délais explicites.
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 90
        configuration.timeoutIntervalForResource = 600
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    /// Session à délais longs, pour l'envoi de fichiers volumineux.
    static let uploadSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 300
        configuration.timeoutIntervalForResource = 1800
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    /// Délais 1 s, 2 s, 4 s… plafonnés à 20 s, ou la valeur imposée par le serveur.
    static func backoff(attempt: Int, retryAfter: Double?) -> Duration {
        if let retryAfter { return .seconds(min(retryAfter, 30)) }
        return .seconds(min(pow(2.0, Double(attempt - 1)), 20))
    }

    /// Envoie une requête et relance sur 429, 5xx et coupures réseau.
    /// `onRetry` permet d'informer l'écran (« nouvelle tentative dans 4 s »).
    static func send(
        _ request: URLRequest,
        provider: String,
        attempts: Int = 3,
        session: URLSession = HTTP.session,
        onRetry: (@Sendable (Int, Duration) -> Void)? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        var lastError: APIError?

        for attempt in 1...max(1, attempts) {
            try Task.checkCancellation()
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw APIError(provider: provider, status: 0, message: "Réponse inattendue.", isTransport: true)
                }
                if (200...299).contains(http.statusCode) {
                    return (data, http)
                }
                lastError = APIError(
                    provider: provider,
                    status: http.statusCode,
                    message: errorMessage(from: data),
                    retryAfter: Double(http.value(forHTTPHeaderField: "Retry-After") ?? "")
                )
            } catch let error as APIError {
                lastError = error
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch {
                lastError = APIError(
                    provider: provider,
                    status: 0,
                    message: error.localizedDescription,
                    isTransport: true
                )
            }

            guard let error = lastError, error.retryable, attempt < attempts else { break }
            let delay = backoff(attempt: attempt, retryAfter: error.retryAfter)
            onRetry?(attempt, delay)
            try await Task.sleep(for: delay)
        }

        throw lastError ?? APIError(provider: provider, status: 0, message: "Échec inconnu.", isTransport: true)
    }

    /// Les API renvoient { "error": { "message": … } } (Google et Perplexity) ou du texte brut.
    static func errorMessage(from data: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = object["error"] as? [String: Any] {
                if let message = error["message"] as? String { return message }
            }
            if let error = object["error"] as? String { return error }
            if let detail = object["detail"] as? String { return detail }
        }
        let text = String(data: data, encoding: .utf8) ?? ""
        return String(text.prefix(300))
    }
}
