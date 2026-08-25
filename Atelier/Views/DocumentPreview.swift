import PDFKit
import QuickLook
import SwiftUI

/// Ouvre un document cité. Pour un PDF, PDFKit permet d'aller directement à la bonne page ;
/// QuickLook, lui, ne sait pas ouvrir à une page donnée. Le reste passe donc par QuickLook,
/// qui gère tous les autres formats.
struct DocumentPreview: View {
    let url: URL
    var page: Int?

    @Environment(\.dismiss) private var dismiss

    private var isPDF: Bool {
        url.pathExtension.lowercased() == "pdf"
    }

    var body: some View {
        NavigationStack {
            Group {
                if isPDF {
                    PDFPreview(url: url, page: page)
                } else {
                    QuickLookPreview(url: url)
                }
            }
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle(url.lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fermer") { dismiss() }
                }
            }
        }
    }
}

private struct PDFPreview: UIViewRepresentable {
    let url: URL
    let page: Int?

    /// Le saut à la page citée n'a lieu qu'une fois : sinon chaque rafraîchissement de la vue
    /// ramènerait le lecteur à cette page et il deviendrait impossible de faire défiler.
    final class Coordinator {
        var didJump = false
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        // Le fichier a été recopié dans le conteneur de l'app par FolderSync : il est lisible
        // directement, sans portée de sécurité à tenir ouverte pendant l'aperçu.
        view.document = PDFDocument(url: url)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        guard !context.coordinator.didJump,
              let page,
              let document = view.document,
              page >= 1, page <= document.pageCount,
              // page(at:) lève une exception hors bornes : l'index est vérifié avant.
              let target = document.page(at: page - 1)
        else { return }
        context.coordinator.didJump = true
        view.go(to: target)
    }
}

private struct QuickLookPreview: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url)
    }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        context.coordinator.url = url
        controller.reloadData()
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL

        init(url: URL) {
            self.url = url
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem {
            url as NSURL
        }
    }
}
