import Foundation

@testable import FilawayCore

/// A deliberately small JSON Schema validator — enough of the vocabulary that
/// `OrganizationPlan.toolSchema` uses (`type`, `enum`, `properties`, `required`,
/// `additionalProperties`, `items`, `anyOf`) to prove that the schema and the
/// Swift codec describe the same documents.
///
/// It exists only in the test target: strict tool use makes the API enforce the
/// schema in production, so shipping a second implementation would just be
/// another thing to keep in sync.
enum JSONSchemaChecker {
    /// Validates `value` against `schema`, returning human-readable failures.
    static func validate(_ value: JSONValue, against schema: JSONValue, path: String = "$") -> [String] {
        guard let schema = schema.objectValue else { return ["\(path): schema is not an object"] }
        var errors: [String] = []

        if let branches = schema["anyOf"]?.arrayValue {
            let matches = branches.contains { validate(value, against: $0, path: path).isEmpty }
            if !matches { errors.append("\(path): matches none of the \(branches.count) anyOf branches") }
            return errors
        }

        if let type = schema["type"]?.stringValue, !matches(value: value, type: type) {
            errors.append("\(path): is \(value.typeName), expected \(type)")
            return errors
        }

        if let allowed = schema["enum"]?.arrayValue, !allowed.contains(value) {
            errors.append("\(path): \(value) is not one of \(allowed)")
        }

        if let items = schema["items"], let array = value.arrayValue {
            for (index, element) in array.enumerated() {
                errors += validate(element, against: items, path: "\(path)[\(index)]")
            }
        }

        if let object = value.objectValue {
            let properties = schema["properties"]?.objectValue ?? [:]
            for name in schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? [] where object[name] == nil {
                errors.append("\(path): missing required \"\(name)\"")
            }
            if schema["additionalProperties"] == .bool(false) {
                for name in object.keys.sorted() where properties[name] == nil {
                    errors.append("\(path): unexpected property \"\(name)\"")
                }
            }
            for (name, sub) in properties {
                guard let child = object[name] else { continue }
                errors += validate(child, against: sub, path: "\(path).\(name)")
            }
        }

        return errors
    }

    private static func matches(value: JSONValue, type: String) -> Bool {
        switch type {
        case "object": return value.objectValue != nil
        case "array": return value.arrayValue != nil
        case "string": return value.stringValue != nil
        case "boolean": return value.boolValue != nil
        case "integer": return value.intValue != nil
        case "number": return value.doubleValue != nil
        case "null": return value.isNull
        default: return true
        }
    }

    /// Structural check of the schema *document* itself: every object node
    /// closes with `additionalProperties: false`, declares `required`, and lists
    /// only properties it defines. Strict tool use needs all three.
    static func lint(_ schema: JSONValue, path: String = "$") -> [String] {
        guard let object = schema.objectValue else { return ["\(path): not an object"] }
        var errors: [String] = []

        if let branches = object["anyOf"]?.arrayValue {
            for (index, branch) in branches.enumerated() {
                errors += lint(branch, path: "\(path).anyOf[\(index)]")
            }
        }

        if object["type"] == .string("object") {
            guard let properties = object["properties"]?.objectValue else {
                return errors + ["\(path): an object schema without \"properties\""]
            }
            if object["additionalProperties"] != .bool(false) {
                errors.append("\(path): strict tool use needs \"additionalProperties\": false")
            }
            guard let required = object["required"]?.arrayValue else {
                return errors + ["\(path): an object schema without \"required\""]
            }
            for name in required.compactMap(\.stringValue) where properties[name] == nil {
                errors.append("\(path): \"\(name)\" is required but not defined")
            }
            for (name, sub) in properties {
                errors += lint(sub, path: "\(path).\(name)")
            }
        }

        if object["type"] == .string("array") {
            guard let items = object["items"] else {
                return errors + ["\(path): an array schema without \"items\""]
            }
            errors += lint(items, path: "\(path)[]")
        }

        return errors
    }
}

/// A tiny deterministic PRNG, so the property-style tests fail reproducibly.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
