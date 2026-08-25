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

    private let monitor = NWPathMonitor()
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
