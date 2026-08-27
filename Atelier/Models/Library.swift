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
    /// Nombre d'échecs consécutifs à l'indexation. **Facultatif à dessein** : un champ
    /// optionnel absent du fichier se relit sans erreur, et un registre déjà constitué
    /// survit donc à cette mise à jour.
    var failureCount: Int?
    /// Date avant laquelle il est inutile de réessayer. Sans elle, un fichier en échec
    /// était relu, téléchargé depuis iCloud et renvoyé à chaque passage au premier plan —
    /// de quoi occuper l'app en permanence et dépenser pour rien.
    var retryAfter: Date?

    /// Au-delà, on cesse d'essayer seul : c'est un défaut du fichier, pas un incident.
    static let maximumAttempts = 4

    /// Empreinte bon marché : taille + date de modification suffisent à repérer un changement.
    var signature: String { "\(size)-\(Int(modified.timeIntervalSince1970))" }
    /// Signature au moment de l'indexation, pour savoir si le fichier a bougé depuis.
    var indexedSignature: String?

    var needsIndexing: Bool {
        switch status {
        case .cataloged: true
        case .indexed: indexedSignature != signature
        // Une erreur mérite un nouvel essai — c'est souvent un téléchargement iCloud inachevé —
        // mais pas immédiatement, et pas indéfiniment. Sans ce délai, chaque retour dans l'app
        // relançait le téléchargement et l'envoi de tous les fichiers en échec.
        case .failed, .downloading: isRetryDue
        // Ces deux-là ne changeront pas d'avis : les réessayer ne ferait que relire pour rien
        // un fichier parfois très gros, à chaque scan.
        case .unsupported, .tooLarge: false
        }
    }

    /// Vrai quand le délai d'attente est écoulé et qu'il reste des essais.
    var isRetryDue: Bool {
        guard (failureCount ?? 0) < FileEntry.maximumAttempts else { return false }
        guard let retryAfter else { return true }
        return retryAfter <= .now
    }

    /// En échec, mais mis en attente : ni à réessayer maintenant, ni perdu.
    var isWaitingToRetry: Bool {
        (status == .failed || status == .downloading) && !isRetryDue
    }

    /// Délai avant le prochain essai : une minute, puis cinq, vingt, une heure.
    static func backoff(after failures: Int) -> TimeInterval {
        let steps: [TimeInterval] = [60, 300, 1200, 3600]
        return steps[min(max(failures - 1, 0), steps.count - 1)]
    }

    var fileExtension: String {
        (name as NSString).pathExtension.lowercased()
    }

    static func makeID(folderID: UUID, relativePath: String) -> String {
        "\(folderID.uuidString)/\(relativePath)".lowercased()
    }
}

/// Ce que l'app sait envoyer au corpus, et comment.
///
/// Deux familles. Celle que **Gemini accepte telle quelle** — la liste des types MIME admis
/// par File Search est publiée, et elle est plus étroite qu'il n'y paraît : `application/rtf`,
/// `application/vnd.ms-powerpoint` ou `application/epub+zip` n'y figurent pas, et un fichier
/// envoyé sous ces types est refusé sans autre explication qu'une erreur sur `mime_type`.
/// Et celle que **l'app convertit sur l'appareil** avant de l'envoyer : le texte est extrait
/// ici, puis transmis en `text/plain`.
///
/// Audio, vidéo et images restent au catalogue : la documentation indique explicitement que
/// File Search ne les prend pas en charge, sous aucun type.
enum SupportedTypes {
    /// Envoyés tels quels, sous un type MIME figurant dans la liste officielle.
    static let native: Set<String> = [
        "pdf", "txt", "text", "md", "markdown", "rtf", "html", "htm", "xml", "json",
        "csv", "tsv", "doc", "docx", "dotx", "odt", "xls", "xlsx", "pptx",
        "swift", "js", "mjs", "ts", "tsx", "jsx", "py", "java", "c", "h", "cpp", "cc", "hpp",
        "go", "rb", "rs", "kt", "cs", "php", "pl", "lua", "r", "scala", "sql", "sh", "bash",
        "zsh", "css", "scss", "sass", "yaml", "yml", "tex", "bib", "diff", "patch", "log",
        "srt", "vtt", "ics", "vcf", "toml", "ini", "conf", "properties",
    ]

    /// Refusés par Gemini, mais dont l'app sait tirer le texte avant de l'envoyer.
    static let converted: Set<String> = [
        "epub", "ods", "odp", "odg", "ppt", "pages", "numbers", "key", "pptm", "docm", "xlsm",
    ]

    static let extensions: Set<String> = native.union(converted)

    /// Limite documentée : 100 Mo par fichier.
    static let maxFileBytes: Int64 = 100 * 1024 * 1024

    static func isSupported(_ name: String) -> Bool {
        extensions.contains((name as NSString).pathExtension.lowercased())
    }

    /// Vrai si le texte doit être extrait sur l'appareil avant l'envoi.
    static func needsConversion(_ name: String) -> Bool {
        converted.contains((name as NSString).pathExtension.lowercased())
    }

    /// Type MIME envoyé à Gemini. **Chaque valeur ci-dessous figure dans la liste officielle
    /// des types admis par File Search** : une valeur plausible mais absente de cette liste
    /// fait rejeter le fichier. En cas de doute, `text/plain` passe toujours.
    static func mimeType(for name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "pdf": "application/pdf"
        case "md", "markdown": "text/markdown"
        case "rtf": "text/rtf"
        case "html", "htm": "text/html"
        case "xml": "text/xml"
        case "json": "application/json"
        case "csv": "text/csv"
        case "tsv": "text/tab-separated-values"
        case "doc": "application/msword"
        case "docx", "dotx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case "odt": "application/vnd.oasis.opendocument.text"
        case "pptx": "application/vnd.openxmlformats-officedocument.presentationml.presentation"
        case "xls": "application/vnd.ms-excel"
        case "xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        case "css": "text/css"
        case "js", "mjs": "text/javascript"
        case "py": "text/x-python"
        case "swift": "text/x-swift"
        case "java": "text/x-java"
        case "c", "h": "text/x-c"
        case "cpp", "cc", "hpp": "text/x-c++src"
        case "go": "text/x-go"
        case "rs": "text/x-rust"
        case "rb": "text/x-ruby-script"
        case "sh", "bash", "zsh": "text/x-sh"
        case "sql": "text/x-sql"
        case "tex": "text/x-tex"
        case "yaml", "yml": "text/yaml"
        case "vtt": "text/vtt"
        case "ics": "text/calendar"
        case "vcf": "text/vcard"
        // Tout le reste part en texte simple : c'est le type le plus sûr de la liste.
        default: "text/plain"
        }
    }
}
