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

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        // Le document vit dans un dossier à portée de sécurité : l'accès est ouvert par
        // FolderSync avant l'affichage et refermé quand la vue disparaît.
        if view.document == nil {
            view.document = PDFDocument(url: url)
        }
        if let page, let document = view.document,
           page >= 1, page <= document.pageCount,
           let target = document.page(at: page - 1) {
            view.go(to: target)
        }
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
