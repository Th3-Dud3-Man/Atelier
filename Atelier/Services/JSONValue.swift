import Foundation

/// Petite valeur JSON, utilisée pour décrire les schémas de réponse envoyés à Gemini.
/// Les littéraux Swift se lisent alors presque comme du JSON.
indirect enum JSONValue: Encodable, Sendable {
    case string(String)
    case number(Double)
    case integer(Int)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

extension JSONValue: ExpressibleByStringLiteral {
    init(stringLiteral value: String) { self = .string(value) }
}

extension JSONValue: ExpressibleByIntegerLiteral {
    init(integerLiteral value: Int) { self = .integer(value) }
}

extension JSONValue: ExpressibleByBooleanLiteral {
    init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension JSONValue: ExpressibleByArrayLiteral {
    init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
}

extension JSONValue: ExpressibleByDictionaryLiteral {
    init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(uniqueKeysWithValues: elements))
    }
}

/// Raccourcis pour écrire les schémas Gemini, dont les types sont en MAJUSCULES
/// (dialecte OpenAPI — voir NOTES_API.md §3.2).
extension JSONValue {
    /// Un objet de schéma, avec ses propriétés et la liste des champs obligatoires.
    static func schemaObject(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
        var node: [String: JSONValue] = [
            "type": "OBJECT",
            "properties": .object(properties),
        ]
        if !required.isEmpty {
            node["required"] = .array(required.map { .string($0) })
        }
        return .object(node)
    }

    static func stringField(_ description: String) -> JSONValue {
        .object(["type": "STRING", "description": .string(description)])
    }

    static func boolField(_ description: String) -> JSONValue {
        .object(["type": "BOOLEAN", "description": .string(description)])
    }

    static func stringList(_ description: String) -> JSONValue {
        .object([
            "type": "ARRAY",
            "description": .string(description),
            "items": .object(["type": "STRING"]),
        ])
    }

    static func enumField(_ description: String, _ cases: [String]) -> JSONValue {
        .object([
            "type": "STRING",
            "description": .string(description),
            "enum": .array(cases.map { .string($0) }),
        ])
    }
}
