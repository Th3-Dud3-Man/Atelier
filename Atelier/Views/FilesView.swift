import SwiftUI
import UniformTypeIdentifiers

/// Mes fichiers : dossiers surveillés, corpus indexé, catalogue, et l'état de la synchronisation.
struct FilesView: View {
    @Environment(AppStore.self) private var store
    @Environment(FolderSync.self) private var sync
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var showingPicker = false
    @State private var confirmingReindex = false
    @State private var folderToRemove: WatchedFolder?

    private var indexed: [FileEntry] {
        filter(store.indexedFiles).sorted { ($0.indexedAt ?? .distantPast) > ($1.indexedAt ?? .distantPast) }
    }

    private var cataloged: [FileEntry] {
        filter(store.catalogedFiles).sorted { $0.modified > $1.modified }
    }

    private func filter(_ files: [FileEntry]) -> [FileEntry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return files }
        return files.filter {
            $0.name.lowercased().contains(needle) || $0.relativePath.lowercased().contains(needle)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                statusSection
                foldersSection
                if !indexed.isEmpty || !query.isEmpty {
                    indexedSection
                }
                if !cataloged.isEmpty || !query.isEmpty {
                    catalogedSection
                }
                limitsSection
            }
            .listStyle(.insetGrouped)
            .searchable(text: $query, prompt: "Rechercher un fichier par nom")
            .navigationTitle("Mes fichiers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Fermer") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            showingPicker = true
                        } label: {
                            Label("Ajouter un dossier", systemImage: "folder.badge.plus")
                        }
                        Button {
                            sync.scanAllInBackground()
                        } label: {
                            Label("Scanner maintenant", systemImage: "arrow.clockwise")
                        }
                        .disabled(store.folders.isEmpty || sync.isScanning)
                        Divider()
                        Button(role: .destructive) {
                            confirmingReindex = true
                        } label: {
                            Label("Tout réindexer", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .disabled(store.folders.isEmpty || sync.isScanning)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .fileImporter(
                isPresented: $showingPicker,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: false
            ) { result in
                if case .success(let urls) = result, let url = urls.first {
                    sync.addFolder(url: url)
                }
            }
            .confirmationDialog(
                "Tout réindexer ?",
                isPresented: $confirmingReindex,
                titleVisibility: .visible
            ) {
                Button("Réindexer", role: .destructive) {
                    Task { await sync.reindexAll() }
                }
            } message: {
                Text("Le corpus est vidé puis reconstruit. Selon le nombre de fichiers, "
                     + "cela peut prendre un moment et coûter quelques centimes d'indexation.")
            }
            .confirmationDialog(
                "Retirer ce dossier ?",
                isPresented: Binding(get: { folderToRemove != nil }, set: { if !$0 { folderToRemove = nil } }),
                titleVisibility: .visible
            ) {
                Button("Retirer", role: .destructive) {
                    if let folder = folderToRemove { sync.removeFolder(folder) }
                    folderToRemove = nil
                }
            } message: {
                Text("Ses fichiers quittent le corpus et le catalogue. Vos documents, eux, ne sont pas touchés.")
            }
        }
    }

    // ── Sections ─────────────────────────────────────────────────────

    @ViewBuilder
    private var statusSection: some View {
        if sync.isScanning || sync.progressText != nil || sync.lastError != nil {
            Section {
                if let progress = sync.progressText {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(progress).font(.footnote).foregroundStyle(.secondary)
                        Spacer()
                        Button("Arrêter") { sync.cancel() }
                            .font(.footnote)
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.atelierAccent)
                    }
                }
                if let error = sync.lastError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private var foldersSection: some View {
        Section("Dossiers surveillés") {
            if store.folders.isEmpty {
                Button {
                    showingPicker = true
                } label: {
                    Label("Choisir un dossier iCloud", systemImage: "folder.badge.plus")
                }
            }
            ForEach(store.folders) { folder in
                VStack(alignment: .leading, spacing: 3) {
                    Text(folder.displayName).font(.body)
                    Text(folderSubtitle(folder))
                        .font(.caption)
                        .foregroundStyle(folder.needsReselection ? .red : .secondary)
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        folderToRemove = folder
                    } label: {
                        Label("Retirer", systemImage: "trash")
                    }
                }
            }
        }
    }

    private func folderSubtitle(_ folder: WatchedFolder) -> String {
        if folder.needsReselection {
            return "Accès perdu — touchez « Ajouter un dossier » pour le redésigner."
        }
        var parts = ["\(folder.fileCount) fichiers", "\(folder.indexedCount) indexés"]
        if let scan = folder.lastScan {
            parts.append("scan \(scan.formatted(date: .omitted, time: .shortened))")
        }
        return parts.joined(separator: " · ")
    }

    private var indexedSection: some View {
        Section("Indexés (\(indexed.count))") {
            if indexed.isEmpty {
                Text("Aucun fichier indexé ne correspond.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(indexed) { file in
                fileRow(file, subtitle: indexedSubtitle(file))
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            Task { await sync.unindex(file) }
                        } label: {
                            Label("Retirer du corpus", systemImage: "minus.circle")
                        }
                    }
            }
        }
    }

    private func indexedSubtitle(_ file: FileEntry) -> String {
        var parts = [byteText(file.size)]
        if let date = file.indexedAt {
            parts.append("indexé le \(date.formatted(date: .abbreviated, time: .omitted))")
        }
        if !file.relativePath.isEmpty && file.relativePath != file.name {
            parts.append(file.relativePath)
        }
        return parts.joined(separator: " · ")
    }

    private var catalogedSection: some View {
        Section("Catalogués, non indexés (\(cataloged.count))") {
            if cataloged.isEmpty {
                Text("Rien au catalogue.").font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(cataloged) { file in
                HStack {
                    fileRow(file, subtitle: catalogedSubtitle(file))
                    if file.status == .cataloged || file.status == .failed {
                        // « trop volumineux » et « non pris en charge » n'offrent pas de bouton :
                        // il n'y a rien à réessayer.
                        Spacer()
                        Button("Indexer") {
                            Task { _ = try? await sync.indexOnDemand(fileID: file.id) }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    private func catalogedSubtitle(_ file: FileEntry) -> String {
        if let error = file.errorMessage, !error.isEmpty {
            return error
        }
        var parts = [byteText(file.size), file.status.label]
        if !file.relativePath.isEmpty && file.relativePath != file.name {
            parts.append(file.relativePath)
        }
        return parts.joined(separator: " · ")
    }

    private func fileRow(_ file: FileEntry, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(file.name).font(.body).lineLimit(2)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(file.status.isProblem ? .red : .secondary)
                .lineLimit(2)
        }
        .padding(.vertical, 1)
    }

    private var limitsSection: some View {
        Section("Limites de Gemini") {
            let bytes = store.indexedFiles.reduce(Int64(0)) { $0 + $1.size }
            VStack(alignment: .leading, spacing: 6) {
                Text("Corpus envoyé : \(byteText(bytes)) — l'empreinte réelle chez Google est "
                     + "d'environ trois fois cette taille, soit \(byteText(bytes * 3)).")
                Text("Un fichier ne peut pas dépasser 100 Mo. Le stockage lui-même est gratuit ; "
                     + "seule l'indexation est facturée, une fois par fichier.")
                if bytes * 3 > 8 * 1024 * 1024 * 1024 {
                    Text("Vous approchez de la limite de 10 Go du palier 1.")
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func byteText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
