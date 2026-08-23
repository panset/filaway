import Foundation

/// A fully general JSON value.
///
/// The AI layer needs to carry JSON it does not own: tool `input_schema`
/// documents, the `input` object of a `tool_use` block, and the raw bodies
/// stored in replay fixtures. `JSONValue` keeps those exact, so a plan decoder
/// can *parse* tool input rather than string-match it (which is the documented
/// trap on current models: JSON string escaping in `input` varies).
public enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case integer(Int)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    // MARK: - Accessors

    public var isNull: Bool { self == .null }

    public var boolValue: Bool? {
        if case let .bool(value) = self { return value }
        return nil
    }

    public var intValue: Int? {
        switch self {
        case let .integer(value): return value
        case let .number(value) where value.rounded() == value: return Int(value)
        default: return nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case let .integer(value): return Double(value)
        case let .number(value): return value
        default: return nil
        }
    }

    public var stringValue: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case let .array(value) = self { return value }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case let .object(value) = self { return value }
        return nil
    }

    public subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }

    public subscript(index: Int) -> JSONValue? {
        guard let array = arrayValue, array.indices.contains(index) else { return nil }
        return array[index]
    }

    /// The JSON type name, as JSON Schema spells it.
    public var typeName: String {
        switch self {
        case .null: return "null"
        case .bool: return "boolean"
        case .integer: return "integer"
        case .number: return "number"
        case .string: return "string"
        case .array: return "array"
        case .object: return "object"
        }
    }

    // MARK: - Bridging

    /// Wraps a `JSONSerialization`-style value (`NSNumber`, `NSNull`, …).
    public init(any value: Any) {
        switch value {
        case is NSNull:
            self = .null
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else if let int = Int(exactly: number) {
                self = .integer(int)
            } else {
                self = .number(number.doubleValue)
            }
        case let string as String:
            self = .string(string)
        case let array as [Any]:
            self = .array(array.map(JSONValue.init(any:)))
        case let dictionary as [String: Any]:
            self = .object(dictionary.mapValues(JSONValue.init(any:)))
        case let value as JSONValue:
            self = value
        default:
            self = .null
        }
    }

    /// Decodes JSON text (or bytes) into a value.
    public static func parse(_ data: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// Decodes JSON text into a value.
    public static func parse(_ text: String) throws -> JSONValue {
        try parse(Data(text.utf8))
    }

    /// Serialises with sorted keys, so the same value always produces the same
    /// bytes — which is what makes fixture hashing stable.
    public func canonicalData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// Pretty, sorted JSON — used for fixtures a human has to read and diff.
    public func prettyData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// Every string that appears anywhere in the value, keys included.
    ///
    /// The exclusion tests use this to assert that no excluded note text ever
    /// reaches a recorded request body (FR-4.5).
    public var allStrings: [String] {
        switch self {
        case let .string(value): return [value]
        case let .array(values): return values.flatMap(\.allStrings)
        case let .object(values): return values.flatMap { [$0.key] + $0.value.allStrings }
        default: return []
        }
    }
}

// MARK: - Codable

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not a JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .bool(value): try container.encode(value)
        case let .integer(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        }
    }
}

// MARK: - Literals

extension JSONValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension JSONValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = .integer(value) }
}

extension JSONValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .number(value) }
}

extension JSONValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension JSONValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
}

extension JSONValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, latest in latest }))
    }
}

extension JSONValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) { self = .null }
}

extension JSONValue: CustomStringConvertible {
    public var description: String {
        guard let data = try? canonicalData(), let text = String(data: data, encoding: .utf8) else {
            return "<unencodable JSON>"
        }
        return text
    }
}
