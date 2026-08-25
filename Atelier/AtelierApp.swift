import SwiftUI

@main
struct AtelierApp: App {
    // Sans valeur par défaut : l'expression par défaut serait évaluée en plus de celle
    // de l'initialiseur, et le fichier JSON serait chargé deux fois au lancement.
    @State private var store: AppStore
    @State private var sync: FolderSync
    @State private var engine: SearchEngine
    @State private var network = NetworkMonitor()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let store = AppStore()
        let sync = FolderSync(store: store)
        _store = State(initialValue: store)
        _sync = State(initialValue: sync)
        _engine = State(initialValue: SearchEngine(store: store, indexer: sync))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(sync)
                .environment(engine)
                .environment(network)
                .tint(.atelierAccent)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                // Re-scan incrémental à chaque retour au premier plan : c'est ce qui remplace
                // NSMetadataQuery, peu fiable sur un dossier externe.
                if store.settings.autoScan {
                    sync.scanAllInBackground()
                }
            case .background:
                Task { await store.saveNow() }
            default:
                break
            }
        }
    }
}
