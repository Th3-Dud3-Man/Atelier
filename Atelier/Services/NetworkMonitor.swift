import Network
import Observation

/// Sait si l'appareil a une route réseau. Sert à désactiver la recherche avec une phrase claire
/// plutôt qu'à laisser un appel échouer, et à afficher « Hors ligne » sur l'accueil.
///
/// `Network` fait partie du système : ce n'est pas une dépendance extérieure.
@MainActor
@Observable
final class NetworkMonitor {
    private(set) var isOnline = true

    // Le deinit d'une classe isolée sur un acteur est lui-même nonisolated et ne peut atteindre
    // qu'une propriété Sendable. NWPathMonitor ne l'est pas ; l'annotation est sûre ici :
    // la propriété est constante, et cancel() est conçu pour être appelé de n'importe où.
    nonisolated(unsafe) private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "fr.latelier.network")

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in
                self?.isOnline = online
            }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }
}
