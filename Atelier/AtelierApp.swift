import SwiftUI

@main
struct AtelierApp: App {
    @State private var store = AppStore()
    @State private var sync: FolderSync
    @State private var engine: SearchEngine
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
