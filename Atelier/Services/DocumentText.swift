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

    /// Formats que Gemini refuse, et dont on sait tirer le texte ici.
    static let convertible: Set<String> = [
        "epub", "ods", "odp", "ppt", "doc", "pages", "numbers", "key", "odg",
    ]

    /// Rend le texte du document, ou `nil` si l'on n'en tire rien d'exploitable.
    static func extract(from data: Data, name: String) -> String? {
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
            text = nil
        }

        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Moins de deux cents caractères tirés d'un document entier : l'extraction a échoué,
        // et envoyer ce résidu polluerait le corpus sans rien apporter.
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

    /// Dernier recours : on relève les suites de caractères lisibles. C'est grossier, mais
    /// sur une lettre ou une note cela rend le texte ; sur un document complexe, le contrôle
    /// des deux cents caractères écartera le résultat.
    private static func fromLegacyBinary(_ data: Data) -> String? {
        var runs: [String] = []
        var current = ""
        // Le format stocke souvent le texte en UTF-16 : un octet sur deux est nul.
        for scalar in data {
            if scalar == 0 { continue }
            if scalar >= 0x20 && scalar < 0x7F {
                current.unicodeScalars.append(Unicode.Scalar(scalar))
            } else if scalar >= 0xC0, let mapped = Unicode.Scalar(UInt32(scalar)) {
                current.unicodeScalars.append(mapped)   // latin-1 approximatif
            } else {
                if current.count >= 12 { runs.append(current) }
                current = ""
            }
        }
        if current.count >= 12 { runs.append(current) }
        let joined = runs.joined(separator: " ")
        return joined.isEmpty ? nil : joined
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
