import SwiftUI

/// Sur iPhone, une pile simple. Sur iPad, l'historique en barre latérale repliable
/// et la recherche en détail.
struct RootView: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(SearchEngine.self) private var engine
    @State private var router = Router()
    @State private var sidebar = NavigationSplitViewVisibility.automatic

    var body: some View {
        Group {
            if sizeClass == .regular {
                splitLayout
            } else {
                stackLayout
            }
        }
        .environment(router)
        .sheet(isPresented: Binding(get: { router.showingFiles }, set: { router.showingFiles = $0 })) {
            FilesView()
        }
        .sheet(isPresented: Binding(get: { router.showingSettings }, set: { router.showingSettings = $0 })) {
            SettingsView()
        }
        .sheet(item: Binding(get: { router.transcript }, set: { router.transcript = $0 })) { draft in
            TranscriptView(draft: draft)
        }
        .background(shortcuts)
    }

    // ── iPhone ───────────────────────────────────────────────────────

    private var stackLayout: some View {
        NavigationStack(path: Binding(get: { router.path }, set: { router.path = $0 })) {
            HomeView()
                .navigationDestination(for: Router.Screen.self) { screen in
                    switch screen {
                    case .results: ResultsView()
                    }
                }
        }
        .sheet(isPresented: Binding(get: { router.showingHistory }, set: { router.showingHistory = $0 })) {
            NavigationStack {
                HistoryView(onOpen: { record in
                    router.showingHistory = false
                    engine.open(record)
                    router.showResults()
                })
            }
        }
    }

    // ── iPad ─────────────────────────────────────────────────────────

    private var splitLayout: some View {
        NavigationSplitView(columnVisibility: $sidebar) {
            HistoryView(onOpen: { record in
                engine.open(record)
            })
            .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 420)
        } detail: {
            NavigationStack {
                if engine.record == nil {
                    HomeView()
                } else {
                    ResultsView()
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
    }

    // ── Raccourcis clavier (iPad) ────────────────────────────────────

    private var shortcuts: some View {
        // Des boutons de taille nulle : invisibles à l'écran, actifs au clavier.
        ZStack {
            Button("Nouvelle recherche") {
                engine.reset()
                router.backToHome()
                router.requestFocus()
            }
            .keyboardShortcut("n", modifiers: .command)

            Button("Rechercher") {
                router.requestFocus()
            }
            .keyboardShortcut("k", modifiers: .command)

            Button("Historique") {
                if sizeClass == .regular {
                    sidebar = sidebar == .detailOnly ? .all : .detailOnly
                } else {
                    router.showingHistory.toggle()
                }
            }
            .keyboardShortcut("y", modifiers: .command)

            Button("Réglages") {
                router.showingSettings = true
            }
            .keyboardShortcut(",", modifiers: .command)

            Button("Mes fichiers") {
                router.showingFiles = true
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
}
