import SwiftUI

/// Historique : groupé par jour, cherchable, rouvrable. Le total du mois est en tête,
/// et l'engrenage y donne accès aux réglages — ils ne figurent pas sur l'accueil.
struct HistoryView: View {
    var onOpen: (SearchRecord) -> Void

    @Environment(AppStore.self) private var store
    @Environment(Router.self) private var router
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var filtered: [SearchRecord] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return store.searches }
        return store.searches.filter {
            $0.question.lowercased().contains(needle) || $0.synthesis.lowercased().contains(needle)
        }
    }

    private var grouped: [(day: Date, records: [SearchRecord])] {
        let calendar = Calendar.current
        let groups = Dictionary(grouping: filtered) { calendar.startOfDay(for: $0.createdAt) }
        return groups.keys.sorted(by: >).map { ($0, groups[$0]?.sorted { $0.createdAt > $1.createdAt } ?? []) }
    }

    var body: some View {
        List {
            Section {
                monthHeader
            }

            if filtered.isEmpty {
                ContentUnavailableView(
                    query.isEmpty ? "Aucune recherche" : "Aucun résultat",
                    systemImage: "clock.arrow.circlepath",
                    description: Text(query.isEmpty
                                      ? "Vos recherches apparaîtront ici, groupées par jour."
                                      : "Aucune recherche ne correspond à « \(query) ».")
                )
            }

            ForEach(grouped, id: \.day) { group in
                Section(dayLabel(group.day)) {
                    ForEach(group.records) { record in
                        Button {
                            onOpen(record)
                        } label: {
                            row(record)
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                store.deleteSearch(id: record.id)
                            } label: {
                                Label("Supprimer", systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $query, prompt: "Rechercher dans l'historique")
        .navigationTitle("Historique")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    router.showingSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Réglages")
            }
            if sizeClass != .regular {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Fermer") { dismiss() }
                }
            }
        }
    }

    private var monthHeader: some View {
        let total = store.monthTotal()
        let cap = store.settings.monthlyCapUSD
        return VStack(alignment: .leading, spacing: 4) {
            Text("\(monthName()) : \(CostModel.formatEUR(total, prices: store.settings.prices)) "
                 + "sur \(CostModel.formatEUR(cap, prices: store.settings.prices))")
                .font(.subheadline)
                .foregroundStyle(.primary)
            if cap > 0 {
                ProgressView(value: min(total / cap, 1))
                    .tint(total >= cap ? .red : Color.atelierAccent)
            }
            if store.capReached {
                Text("Plafond atteint : les recherches payantes sont suspendues.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 4)
    }

    private func row(_ record: SearchRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(record.question)
                .font(.body)
                .lineLimit(2)
                .foregroundStyle(.primary)
            HStack(spacing: 6) {
                Text(record.createdAt.formatted(date: .omitted, time: .shortened))
                Text("·")
                Text(record.effectiveSource.label)
                Text("·")
                Text(CostModel.format(record.costUSD))
                if !record.followUps.isEmpty {
                    Text("·")
                    Text("\(record.followUps.count) suite\(record.followUps.count > 1 ? "s" : "")")
                }
                if record.status == .failed {
                    Text("·")
                    Text("échec").foregroundStyle(.red)
                }
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    private func dayLabel(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Aujourd'hui" }
        if calendar.isDateInYesterday(day) { return "Hier" }
        return day.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }

    private func monthName() -> String {
        let name = Date.now.formatted(.dateTime.month(.wide))
        return name.prefix(1).uppercased() + name.dropFirst()
    }
}
