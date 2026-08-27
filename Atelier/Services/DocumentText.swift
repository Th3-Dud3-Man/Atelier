import Compression
import Foundation

/// Extrait le texte d'un document que Gemini n'accepte pas tel quel.
///
/// La plupart des formats bureautiques modernes — docx, xlsx, pptx, odt, epub, Pages —
/// sont des archives ZIP contenant du XML. Il n'y a donc rien à « convertir » : il suffit
/// d'ouvrir l'archive, de lire la bonne pièce et d'en retirer les balises. Tout se fait
/// sur l'appareil, sans bibliothèque extérieure, et seul le texte obtenu part chez Google.
///
/// Le format `.doc` d'avant 2007 fait exception : c'est un format binaire propriétaire dont
/// la lecture correcte demanderait un analyseur complet. On en tire ce qu'on peut, et on le
/// dit franchement quand le résultat n'est pas exploitable.
enum DocumentText {

    // ── Reconnaître le format réel, pas celui du nom ─────────────────

    /// Ce qu'un fichier est vraiment, d'après ses premiers octets.
    ///
    /// L'extension ment souvent, et `.doc` est le pire de tous : Word y a enregistré du RTF
    /// et du HTML pendant vingt ans, et un `.docx` renommé `.doc` reste une archive ZIP.
    /// Envoyer un fichier sous un type déduit de son nom, c'est envoyer une devinette.
    enum Format: Equatable {
        case pdf
        /// Archive ZIP : OOXML, OpenDocument, ePub, iWork.
        case officeArchive
        /// Conteneur binaire d'avant 2007 — Word, Excel, PowerPoint 97-2003.
        case legacyBinary
        case rtf
        case html
        case xml
        case plainText
        case unreadable
    }

    static func sniff(_ data: Data) -> Format {
        let head = [UInt8](data.prefix(512))
        guard head.count >= 4 else { return .unreadable }

        func starts(with bytes: [UInt8]) -> Bool {
            head.count >= bytes.count && Array(head.prefix(bytes.count)) == bytes
        }

        if starts(with: [0x25, 0x50, 0x44, 0x46]) { return .pdf }                     // %PDF
        if starts(with: [0x50, 0x4B, 0x03, 0x04]) { return .officeArchive }           // PK..
        if starts(with: [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]) {           // OLE
            return .legacyBinary
        }
        if starts(with: [0x7B, 0x5C, 0x72, 0x74, 0x66]) { return .rtf }               // {\rtf

        // Le texte peut commencer par des blancs ou une marque d'ordre des octets.
        let text = String(decoding: data.prefix(4096), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if text.hasPrefix("<?xml") {
            return text.contains("<html") || text.contains("xhtml") ? .html : .xml
        }
        if text.hasPrefix("<!doctype html") || text.hasPrefix("<html") { return .html }

        // Reste à savoir si c'est lisible. Un fichier binaire est plein d'octets de contrôle.
        let sample = data.prefix(4096)
        guard !sample.isEmpty else { return .unreadable }
        let control = sample.filter { $0 < 0x09 || ($0 > 0x0D && $0 < 0x20) }.count
        return Double(control) / Double(sample.count) < 0.02 ? .plainText : .unreadable
    }

    /// Ce qu'il faut faire d'un fichier : l'envoyer tel quel, en extraire le texte, ou renoncer.
    enum Plan: Equatable {
        case upload(mime: String)
        case convert
        case reject(String)
    }

    static func plan(for data: Data, name: String) -> Plan {
        let ext = (name as NSString).pathExtension.lowercased()

        switch sniff(data) {
        case .pdf:
            return .upload(mime: "application/pdf")

        case .rtf:
            return .upload(mime: "text/rtf")

        case .html:
            return .upload(mime: "text/html")

        case .xml:
            return .upload(mime: "text/xml")

        case .officeArchive:
            // Un vrai OOXML part tel quel : Gemini le lit mieux que nous. Les autres archives
            // — OpenDocument tableur, ePub, iWork — passent par l'extraction.
            guard let archive = Zip(data) else { return .convert }
            if archive.names.contains("word/document.xml") {
                return .upload(mime: "application/vnd.openxmlformats-officedocument.wordprocessingml.document")
            }
            if archive.names.contains("xl/workbook.xml") {
                return .upload(mime: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
            }
            if archive.names.contains("ppt/presentation.xml") {
                return .upload(mime: "application/vnd.openxmlformats-officedocument.presentationml.presentation")
            }
            if archive.names.contains("content.xml") {
                // Seul le traitement de texte OpenDocument figure dans la liste de Gemini.
                let isText = archive.contents(of: "mimetype")?.contains("opendocument.text") == true
                return isText
                    ? .upload(mime: "application/vnd.oasis.opendocument.text")
                    : .convert
            }
            return .convert

        case .legacyBinary:
            // Gemini accepte `application/msword`, mais échoue souvent à en tirer le texte,
            // et son échec nous revient sans explication. On le fait ici, où l'on peut au
            // moins juger du résultat.
            return .convert

        case .plainText:
            return .upload(mime: SupportedTypes.mimeType(for: name))

        case .unreadable:
            return .reject(ext.isEmpty
                ? "Ce fichier n'a pas de contenu lisible."
                : "Ce fichier « .\(ext) » n'a pas de contenu textuel lisible.")
        }
    }

    /// Rend le texte du document, ou `nil` si l'on n'en tire rien d'exploitable.
    static func extract(from data: Data, name: String) -> String? {
        // Le format réel commande, pas l'extension : un `.doc` peut être une archive.
        if sniff(data) == .legacyBinary { return check(fromLegacyBinary(data)) }

        let text: String?
        switch (name as NSString).pathExtension.lowercased() {
        case "docx", "docm", "dotx":
            text = fromZip(data, members: ["word/document.xml"], breakAfter: ["</w:p>"])
        case "pptx", "ppsx":
            text = fromZip(data, prefix: "ppt/slides/slide", suffix: ".xml", breakAfter: ["</a:p>"])
        case "xlsx", "xlsm":
            text = fromSpreadsheet(data)
        case "odt", "ods", "odp", "odg":
            text = fromZip(data, members: ["content.xml"],
                           breakAfter: ["</text:p>", "</text:h>", "</table:table-row>"])
        case "epub":
            text = fromZip(data, prefix: "", suffix: ".xhtml", breakAfter: ["</p>", "</h1>", "</h2>"])
                ?? fromZip(data, prefix: "", suffix: ".html", breakAfter: ["</p>"])
        case "pages", "numbers", "key":
            text = fromZip(data, members: ["Index/Document.iwa"], breakAfter: [])
                ?? fromZip(data, prefix: "", suffix: ".xml", breakAfter: ["</p>"])
        case "ppt", "doc", "xls":
            text = fromLegacyBinary(data)
        default:
            // Nom inconnu mais archive reconnue : on tente quand même les pièces habituelles.
            text = fromZip(data, members: ["word/document.xml", "content.xml"],
                           breakAfter: ["</w:p>", "</text:p>"])
        }
        return check(text)
    }

    /// Moins de deux cents caractères tirés d'un document entier : l'extraction a échoué,
    /// et envoyer ce résidu polluerait le corpus sans rien apporter.
    private static func check(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count >= 200 ? trimmed : nil
    }

    // ── Archives ZIP ─────────────────────────────────────────────────

    private static func fromZip(
        _ data: Data, members: [String], breakAfter: [String]
    ) -> String? {
        guard let archive = Zip(data) else { return nil }
        let pieces = members.compactMap { archive.contents(of: $0) }
        guard !pieces.isEmpty else { return nil }
        return pieces.map { plainText(fromXML: $0, breakAfter: breakAfter) }.joined(separator: "\n\n")
    }

    /// Variante pour les formats dont les pièces sont numérotées : une diapositive, un chapitre.
    private static func fromZip(
        _ data: Data, prefix: String, suffix: String, breakAfter: [String]
    ) -> String? {
        guard let archive = Zip(data) else { return nil }
        let names = archive.names
            .filter { $0.hasPrefix(prefix) && $0.hasSuffix(suffix) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        guard !names.isEmpty else { return nil }
        let pieces = names.compactMap { archive.contents(of: $0) }
            .map { plainText(fromXML: $0, breakAfter: breakAfter) }
            .filter { !$0.isEmpty }
        return pieces.isEmpty ? nil : pieces.joined(separator: "\n\n")
    }

    /// Un classeur : les libellés vivent dans une table partagée, les valeurs dans les feuilles.
    private static func fromSpreadsheet(_ data: Data) -> String? {
        guard let archive = Zip(data) else { return nil }
        var parts: [String] = []
        if let shared = archive.contents(of: "xl/sharedStrings.xml") {
            parts.append(plainText(fromXML: shared, breakAfter: ["</si>"]))
        }
        for name in archive.names.filter({ $0.hasPrefix("xl/worksheets/") && $0.hasSuffix(".xml") })
            .sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
            if let sheet = archive.contents(of: name) {
                parts.append(plainText(fromXML: sheet, breakAfter: ["</row>"]))
            }
        }
        let joined = parts.filter { !$0.isEmpty }.joined(separator: "\n\n")
        return joined.isEmpty ? nil : joined
    }

    // ── Formats binaires d'avant 2007 ────────────────────────────────

    /// Noms de flux et de polices que tout conteneur Word contient, et qui n'ont rien à
    /// faire dans le corpus.
    private static let olePlumbing = [
        "root entry", "worddocument", "objectpool", "compobj", "summaryinformation",
        "documentsummary", "msworddoc", "word.document", "times new roman", "arial",
        "cambria", "calibri", "wingdings", "symbol", "microsoft word", "normal.dot",
    ]

    /// Dernier recours : on relève les suites de caractères lisibles.
    ///
    /// Deux précautions que l'absence de l'une rendait l'app inutilisable. D'abord la vitesse :
    /// la version précédente ajoutait les caractères un par un dans une chaîne, sur le fichier
    /// entier — sur un document de plusieurs mégaoctets, cela occupait l'app pendant des
    /// minutes. On travaille désormais sur les octets, et on s'arrête à douze mégaoctets,
    /// bien au-delà de ce que contient un traitement de texte de cette époque.
    /// Ensuite la qualité : un conteneur binaire est plein de noms de flux et de polices.
    /// On ne garde que ce qui ressemble à de la prose.
    private static func fromLegacyBinary(_ data: Data) -> String? {
        let scanned = data.prefix(12 * 1024 * 1024)
        var runs: [String] = []
        var current: [UInt8] = []
        current.reserveCapacity(512)

        func flush() {
            defer { current.removeAll(keepingCapacity: true) }
            guard current.count >= 12 else { return }
            let text = String(String.UnicodeScalarView(current.map { Unicode.Scalar($0) }))
            if isProse(text) { runs.append(text) }
        }

        scanned.withUnsafeBytes { raw in
            for byte in raw {
                // Le texte est souvent rangé en UTF-16 : un octet sur deux est nul.
                if byte == 0 { continue }
                if (byte >= 0x20 && byte < 0x7F) || byte >= 0xC0 {
                    current.append(byte)
                } else {
                    flush()
                }
            }
        }
        flush()

        let joined = runs.joined(separator: "\n")
        return joined.isEmpty ? nil : joined
    }

    /// Vrai quand une suite de caractères ressemble à une phrase plutôt qu'à un nom de flux.
    private static func isProse(_ text: String) -> Bool {
        let lowered = text.lowercased()
        if olePlumbing.contains(where: lowered.contains) { return false }
        let letters = text.filter { $0.isLetter }.count
        guard Double(letters) / Double(text.count) > 0.6 else { return false }
        // Une suite sans voyelle ni espace est un identifiant, pas une phrase.
        return text.contains(" ") && lowered.contains(where: "aeiouyàâéèêëîïôöùûü".contains)
    }

    // ── XML vers texte ───────────────────────────────────────────────

    /// Retire les balises, en gardant les retours à la ligne là où le format en pose.
    static func plainText(fromXML xml: String, breakAfter: [String]) -> String {
        var marked = xml
        for tag in breakAfter {
            marked = marked.replacingOccurrences(of: tag, with: tag + "\u{2029}")
        }
        marked = marked.replacingOccurrences(of: "<w:tab/>", with: "\t")
        marked = marked.replacingOccurrences(of: "<w:br/>", with: "\u{2029}")
        marked = marked.replacingOccurrences(of: "<text:tab/>", with: "\t")

        var out = ""
        out.reserveCapacity(marked.count / 2)
        var insideTag = false
        for character in marked {
            switch character {
            case "<": insideTag = true
            case ">": insideTag = false
            case "\u{2029}": out.append("\n")
            default: if !insideTag { out.append(character) }
            }
        }
        return tidy(decodeEntities(out))
    }

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var out = text
        for (entity, replacement) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""),
                                      ("&apos;", "'"), ("&#39;", "'"), ("&nbsp;", " ")] {
            out = out.replacingOccurrences(of: entity, with: replacement)
        }
        // Les entités numériques après les nommées, et « &amp; » en dernier : dans l'autre
        // ordre, « &amp;lt; » deviendrait « < » au lieu de « &lt; ».
        while let range = out.range(of: "&#[0-9]{1,6};", options: .regularExpression) {
            let digits = out[range].dropFirst(2).dropLast()
            guard let code = UInt32(digits), let scalar = Unicode.Scalar(code) else {
                out.replaceSubrange(range, with: "")
                continue
            }
            out.replaceSubrange(range, with: String(Character(scalar)))
        }
        return out.replacingOccurrences(of: "&amp;", with: "&")
    }

    /// Resserre les blancs : le XML bureautique en produit des quantités.
    static func tidy(_ text: String) -> String {
        var lines: [String] = []
        var blanks = 0
        for line in text.components(separatedBy: "\n") {
            let clean = line.replacingOccurrences(of: "[ \t]+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            if clean.isEmpty {
                blanks += 1
                if blanks <= 1 { lines.append("") }
            } else {
                blanks = 0
                lines.append(clean)
            }
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// ── Lecteur ZIP minimal ──────────────────────────────────────────────

/// Juste ce qu'il faut pour lire une archive bureautique : le catalogue en fin de fichier,
/// puis chaque pièce demandée. Pas d'écriture, pas de chiffrement, pas de ZIP64 — un document
/// de plus de quatre giga-octets dépasserait de toute façon la limite de Gemini.
struct Zip {
    private let data: Data
    private struct Entry {
        var name: String
        var compressed: Int
        var uncompressed: Int
        var method: UInt16
        var localHeader: Int
    }
    private var entries: [String: Entry] = [:]
    private(set) var names: [String] = []

    init?(_ data: Data) {
        self.data = data
        guard let directory = Self.findCentralDirectory(in: data) else { return nil }
        var offset = directory.offset
        for _ in 0..<directory.count {
            guard offset + 46 <= data.count,
                  Self.uint32(data, offset) == 0x02014b50 else { break }
            let method = Self.uint16(data, offset + 10)
            let compressed = Int(Self.uint32(data, offset + 20))
            let uncompressed = Int(Self.uint32(data, offset + 24))
            let nameLength = Int(Self.uint16(data, offset + 28))
            let extraLength = Int(Self.uint16(data, offset + 30))
            let commentLength = Int(Self.uint16(data, offset + 32))
            let localHeader = Int(Self.uint32(data, offset + 42))
            guard offset + 46 + nameLength <= data.count else { break }
            let nameData = data.subdata(in: (offset + 46)..<(offset + 46 + nameLength))
            if let name = String(data: nameData, encoding: .utf8) {
                entries[name] = Entry(name: name, compressed: compressed,
                                      uncompressed: uncompressed, method: method,
                                      localHeader: localHeader)
                names.append(name)
            }
            offset += 46 + nameLength + extraLength + commentLength
        }
        if entries.isEmpty { return nil }
    }

    /// Contenu textuel d'une pièce de l'archive.
    func contents(of name: String) -> String? {
        guard let entry = entries[name], let bytes = read(entry) else { return nil }
        return String(data: bytes, encoding: .utf8)
            ?? String(data: bytes, encoding: .isoLatin1)
    }

    private func read(_ entry: Entry) -> Data? {
        let header = entry.localHeader
        guard header + 30 <= data.count, Self.uint32(data, header) == 0x04034b50 else { return nil }
        let nameLength = Int(Self.uint16(data, header + 26))
        let extraLength = Int(Self.uint16(data, header + 28))
        let start = header + 30 + nameLength + extraLength
        guard start + entry.compressed <= data.count, entry.compressed > 0 else { return nil }
        let payload = data.subdata(in: start..<(start + entry.compressed))

        switch entry.method {
        case 0: return payload                    // rangé tel quel
        case 8: return Self.inflate(payload, expected: entry.uncompressed)
        default: return nil                       // formats de compression exotiques
        }
    }

    /// `COMPRESSION_ZLIB` désigne, chez Apple, le DEFLATE brut de la RFC 1951 — exactement
    /// ce que contient une archive ZIP, sans en-tête zlib.
    private static func inflate(_ payload: Data, expected: Int) -> Data? {
        // Une pièce annonçant zéro octet, ou un rapport de compression absurde, est suspecte.
        let capacity = expected > 0 ? expected : min(payload.count * 20, 64 * 1024 * 1024)
        guard capacity > 0, capacity <= 256 * 1024 * 1024 else { return nil }

        var output = Data(count: capacity)
        let written = output.withUnsafeMutableBytes { destination -> Int in
            guard let destinationBase = destination.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return payload.withUnsafeBytes { source -> Int in
                guard let sourceBase = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(
                    destinationBase, capacity, sourceBase, payload.count, nil, COMPRESSION_ZLIB
                )
            }
        }
        guard written > 0 else { return nil }
        return output.prefix(written)
    }

    // ── Lecture des entiers, en petit-boutiste ───────────────────────

    private static func uint16(_ data: Data, _ offset: Int) -> UInt16 {
        guard offset + 2 <= data.count else { return 0 }
        return UInt16(data[data.startIndex + offset]) | UInt16(data[data.startIndex + offset + 1]) << 8
    }

    private static func uint32(_ data: Data, _ offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        var value: UInt32 = 0
        for index in (0..<4).reversed() {
            value = value << 8 | UInt32(data[data.startIndex + offset + index])
        }
        return value
    }

    /// Le catalogue se trouve en fin de fichier, derrière un commentaire de longueur variable :
    /// on remonte donc depuis la fin jusqu'à sa signature.
    private static func findCentralDirectory(in data: Data) -> (offset: Int, count: Int)? {
        let maximumComment = 65_557
        let lowest = max(0, data.count - maximumComment)
        var index = data.count - 22
        while index >= lowest {
            if uint32(data, index) == 0x06054b50 {
                let count = Int(uint16(data, index + 10))
                let offset = Int(uint32(data, index + 16))
                guard count > 0, offset >= 0, offset < data.count else { return nil }
                return (offset, count)
            }
            index -= 1
        }
        return nil
    }
}
