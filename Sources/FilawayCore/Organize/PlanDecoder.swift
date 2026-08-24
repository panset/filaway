import Foundation

/// An entry in `actions` the decoder could not turn into a ``PlanAction``.
///
/// Reported rather than thrown: one hallucinated action must not cost the user
/// the six good ones. ``PlanValidator`` turns the report into a warning so the
/// card can still be shown, and the fixtures record it so a prompt regression is
/// visible.
public struct UnknownPlanAction: Sendable, Hashable {
    /// Index in the model's `actions` array.
    public var index: Int
    /// The `action` discriminator, when there was one.
    public var name: String?
    public var reason: String
    public var raw: JSONValue

    public init(index: Int, name: String?, reason: String, raw: JSONValue) {
        self.index = index
        self.name = name
        self.reason = reason
        self.raw = raw
    }
}

/// The result of reading a tool call.
public struct PlanDecoding: Sendable, Hashable {
    public var plan: OrganizationPlan
    public var unknownActions: [UnknownPlanAction]

    public init(plan: OrganizationPlan, unknownActions: [UnknownPlanAction] = []) {
        self.plan = plan
        self.unknownActions = unknownActions
    }
}

public enum PlanDecodingError: Error, Equatable, CustomStringConvertible {
    case notAnObject(String)
    case missingField(String)
    case wrongType(field: String, expected: String, actual: String)
    /// The turn carried no `tool_use` block for the plan tool.
    case noToolUse(expected: String, stopReason: String)
    /// A safety classifier declined (FR-6.4: surface, never retry blindly).
    case refused(category: String?)
    /// `stop_reason: "max_tokens"` — the plan is truncated and unusable.
    case truncated

    public var description: String {
        switch self {
        case let .notAnObject(actual):
            return "Tool input is \(actual), expected an object."
        case let .missingField(field):
            return "Tool input is missing \"\(field)\"."
        case let .wrongType(field, expected, actual):
            return "\"\(field)\" is \(actual), expected \(expected)."
        case let .noToolUse(expected, stopReason):
            return "The reply contained no \"\(expected)\" tool call (stop_reason: \(stopReason))."
        case let .refused(category):
            return category.map { "The model declined this request (\($0))." } ?? "The model declined this request."
        case .truncated:
            return "The reply hit the output cap before the plan was complete."
        }
    }
}

/// Turns a `tool_use` block into an ``OrganizationPlan``.
///
/// Always parses JSON — never string-matches the serialized input, because
/// current models vary their escaping inside `input`.
public enum PlanDecoder {
    /// Reads the forced tool call out of a response.
    ///
    /// - Parameters:
    ///   - context: used to attach CAS preconditions for every note the plan
    ///     touches. Pass `nil` to leave ``OrganizationPlan/preconditions`` empty.
    public static func decode(
        response: AIResponse,
        toolName: String = OrganizationPlan.toolName,
        promptVersion: PromptVersion = .organize,
        context: OrganizeContext? = nil
    ) throws -> PlanDecoding {
        if response.isRefusal {
            throw PlanDecodingError.refused(category: response.stopDetails?.category)
        }
        guard let call = response.toolUse(named: toolName) else {
            if response.isTruncated { throw PlanDecodingError.truncated }
            throw PlanDecodingError.noToolUse(expected: toolName, stopReason: response.stopReason.rawValue)
        }
        if response.isTruncated { throw PlanDecodingError.truncated }
        return try decode(
            toolInput: call.input,
            promptVersion: promptVersion,
            model: response.model,
            context: context
        )
    }

    /// Reads a plan from raw tool input.
    public static func decode(
        toolInput: JSONValue,
        promptVersion: PromptVersion = .organize,
        model: String = AIModel.defaultOrganize.id,
        context: OrganizeContext? = nil
    ) throws -> PlanDecoding {
        guard let object = toolInput.objectValue else {
            throw PlanDecodingError.notAnObject(toolInput.typeName)
        }
        guard let summaryValue = object["summary"] else {
            throw PlanDecodingError.missingField("summary")
        }
        guard let summary = summaryValue.stringValue else {
            throw PlanDecodingError.wrongType(field: "summary", expected: "string", actual: summaryValue.typeName)
        }
        guard let actionsValue = object["actions"] else {
            throw PlanDecodingError.missingField("actions")
        }
        guard let rawActions = actionsValue.arrayValue else {
            throw PlanDecodingError.wrongType(field: "actions", expected: "array", actual: actionsValue.typeName)
        }

        let decoder = JSONDecoder()
        var actions: [PlanAction] = []
        var unknown: [UnknownPlanAction] = []

        for (index, raw) in rawActions.enumerated() {
            let name = raw["action"]?.stringValue
            guard raw.objectValue != nil else {
                unknown.append(UnknownPlanAction(
                    index: index, name: name, reason: "action is \(raw.typeName), expected an object", raw: raw
                ))
                continue
            }
            guard let name else {
                unknown.append(UnknownPlanAction(
                    index: index, name: nil, reason: "no \"action\" discriminator", raw: raw
                ))
                continue
            }
            guard PlanAction.Kind(rawValue: name) != nil else {
                unknown.append(UnknownPlanAction(
                    index: index, name: name, reason: "\"\(name)\" is not in the closed action set", raw: raw
                ))
                continue
            }
            do {
                actions.append(try decoder.decode(PlanAction.self, from: raw.canonicalData()))
            } catch {
                unknown.append(UnknownPlanAction(
                    index: index, name: name, reason: Self.describe(error), raw: raw
                ))
            }
        }

        var plan = OrganizationPlan(
            summary: summary,
            actions: actions,
            promptVersion: promptVersion,
            model: model
        )
        if let context {
            plan.preconditions = context.preconditions(for: plan)
        }
        return PlanDecoding(plan: plan, unknownActions: unknown)
    }

    /// Encodes a plan back into tool-input form — the round trip the fixtures
    /// and the schema tests rely on.
    public static func toolInput(for plan: OrganizationPlan) throws -> JSONValue {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let actions = try plan.actions.map { try JSONValue.parse(encoder.encode($0)) }
        return .object([
            "summary": .string(plan.summary),
            "actions": .array(actions),
        ])
    }

    private static func describe(_ error: Error) -> String {
        guard let decoding = error as? DecodingError else { return "\(error)" }
        switch decoding {
        case let .keyNotFound(key, _):
            return "missing \"\(key.stringValue)\""
        case let .typeMismatch(type, context):
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            return "\(path.isEmpty ? "value" : path) is not \(type)"
        case let .valueNotFound(type, context):
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            return "\(path.isEmpty ? "value" : path) is null, expected \(type)"
        case let .dataCorrupted(context):
            return context.debugDescription
        @unknown default:
            return "\(decoding)"
        }
    }
}
