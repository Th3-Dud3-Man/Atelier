import Foundation

// Registre des fichiers : ce que l'app sait de votre corpus.
// Trois niveaux, comme prévu : indexé (contenu envoyé à Gemini), catalogué (nom seulement),
// non supporté (jamais envoyé, mais connu et cherchable par son nom).

enum FileStatus: String, Codable, Sendable {
    case indexed, cataloged, unsupported, failed, downloading, tooLarge

    var label: String {
        switch self {
        case .indexed: "indexé"
        case .cataloged: "catalogué"
        case .unsupported: "format non pris en charge"
        case .failed: "erreur"
        case .downloading: "téléchargement iCloud"
        case .tooLarge: "trop volumineux"
        }
    }

    /// Vaut-il la peine d'être signalé en rouge ?
    var isProblem: Bool { self == .failed || self == .tooLarge }
}

/// Un dossier iCloud désigné par l'utilisateur, gardé entre deux lancements par un signet.
struct WatchedFolder: Codable, Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var displayName: String
    /// Signet à portée de sécurité, résolu à chaque lancement.
    var bookmark: Data
    var lastScan: Date?
    var fileCount: Int = 0
    var indexedCount: Int = 0
    /// Sous-dossiers ignorés, en chemin relatif.
    var excludedSubpaths: [String] = []
    /// Extensions ignorées, en minuscules et sans point.
    var excludedExtensions: [String] = []
    /// Passe à vrai quand le signet ne se résout plus : il faut redésigner le dossier.
    var needsReselection: Bool = false
}

struct FileEntry: Codable, Identifiable, Hashable, Sendable {
    /// Identifiant stable : dossier + chemin relatif en minuscules.
    var id: String
    var folderID: UUID
    var relativePath: String
    var name: String
    var size: Int64
    var modified: Date
    var status: FileStatus
    /// Nom du document côté Gemini (`fileSearchStores/…/documents/…`), pour le retirer plus tard.
    var storeDocumentName: String?
    var indexedAt: Date?
    var errorMessage: String?
    var lastSeenAt: Date = .now

    /// Empreinte bon marché : taille + date de modification suffisent à repérer un changement.
    var signature: String { "\(size)-\(Int(modified.timeIntervalSince1970))" }
    /// Signature au moment de l'indexation, pour savoir si le fichier a bougé depuis.
    var indexedSignature: String?

    var needsIndexing: Bool {
        switch status {
        case .cataloged: true
        case .indexed: indexedSignature != signature
        // Une erreur mérite un nouvel essai : c'est souvent un téléchargement iCloud inachevé.
        case .failed, .downloading: true
        // Ces deux-là ne changeront pas d'avis : les réessayer ne ferait que relire pour rien
        // un fichier parfois très gros, à chaque scan.
        case .unsupported, .tooLarge: false
        }
    }

    var fileExtension: String {
        (name as NSString).pathExtension.lowercased()
    }

    static func makeID(folderID: UUID, relativePath: String) -> String {
        "\(folderID.uuidString)/\(relativePath)".lowercased()
    }
}

/// Formats acceptés par Gemini File Search. Audio, vidéo et images restent au catalogue :
/// la documentation indique explicitement que File Search ne les prend pas en charge.
enum SupportedTypes {
    static let extensions: Set<String> = [
        "pdf", "txt", "md", "markdown", "rtf", "html", "htm", "xml", "json", "csv", "tsv",
        "doc", "docx", "odt", "ppt", "pptx", "xls", "xlsx", "odp", "ods", "epub",
        "swift", "js", "ts", "py", "java", "c", "h", "cpp", "go", "rb", "sh", "css", "yaml", "yml",
    ]

    /// Limite documentée : 100 Mo par fichier.
    static let maxFileBytes: Int64 = 100 * 1024 * 1024

    static func isSupported(_ name: String) -> Bool {
        extensions.contains((name as NSString).pathExtension.lowercased())
    }

    /// Type MIME envoyé à Gemini. Une valeur générique est acceptable : le service la déduit sinon.
    static func mimeType(for name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "pdf": "application/pdf"
        case "txt": "text/plain"
        case "md", "markdown": "text/markdown"
        case "rtf": "application/rtf"
        case "html", "htm": "text/html"
        case "xml": "text/xml"
        case "json": "application/json"
        case "csv": "text/csv"
        case "tsv": "text/tab-separated-values"
        case "doc": "application/msword"
        case "docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case "odt": "application/vnd.oasis.opendocument.text"
        case "ppt": "application/vnd.ms-powerpoint"
        case "pptx": "application/vnd.openxmlformats-officedocument.presentationml.presentation"
        case "xls": "application/vnd.ms-excel"
        case "xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        case "epub": "application/epub+zip"
        default: "text/plain"
        }
    }
}
