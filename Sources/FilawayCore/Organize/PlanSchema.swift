import Foundation

/// The strict-tool-use JSON Schema for ``OrganizationPlan``.
///
/// Shape rules that matter for strict tool use: **every** object closes itself
/// with `additionalProperties: false` and carries a `required` list, and the
/// action union is a discriminated `anyOf` — each branch pins `action` to a
/// single-value `enum`, which is what lets the model (and the decoder) tell the
/// branches apart without guessing.
///
/// The schema is generated rather than hand-written so it cannot drift from the
/// codec: `PlanSchemaTests` encodes every action case and validates the result
/// against this document.
public extension OrganizationPlan {
    static var toolSchema: JSONValue {
        PlanSchema.root
    }
}

enum PlanSchema {
    // MARK: - Building blocks

    static func object(
        properties: [String: JSONValue],
        required: [String],
        description: String? = nil
    ) -> JSONValue {
        var out: [String: JSONValue] = [
            "type": "object",
            "properties": .object(properties),
            "required": .array(required.map { .string($0) }),
            "additionalProperties": .bool(false),
        ]
        if let description { out["description"] = .string(description) }
        return .object(out)
    }

    static func string(_ description: String) -> JSONValue {
        .object(["type": "string", "description": .string(description)])
    }

    static func boolean(_ description: String) -> JSONValue {
        .object(["type": "boolean", "description": .string(description)])
    }

    static func integer(_ description: String) -> JSONValue {
        .object(["type": "integer", "description": .string(description)])
    }

    static func stringArray(_ description: String) -> JSONValue {
        .object([
            "type": "array",
            "description": .string(description),
            "items": .object(["type": "string"]),
        ])
    }

    static func constant(_ value: String) -> JSONValue {
        .object(["type": "string", "enum": .array([.string(value)])])
    }

    // MARK: - Shared definitions

    static let noteRef = object(
        properties: [
            "id": string("The note's id, exactly as given in the library context. Preferred."),
            "path": string("The note's path relative to the library root, e.g. \"Commands/curl.md\"."),
        ],
        required: [],
        description: "A reference to an existing note. Give \"id\" whenever you know it."
    )

    static let textRange = object(
        properties: [
            "start": integer("Character offset of the segment in the source note."),
            "length": integer("Length of the segment in characters."),
        ],
        required: ["start", "length"],
        description: "Optional, advisory. The segment text is what actually locates the move."
    )

    static let segmentDestination = JSONValue.object([
        "description": "Where the segment goes: an existing note, or a new one.",
        "anyOf": .array([
            object(
                properties: [
                    "kind": constant("existingNote"),
                    "note": noteRef,
                ],
                required: ["kind", "note"]
            ),
            object(
                properties: [
                    "kind": constant("newNote"),
                    "title": string("Title of the note to create. Becomes the filename, so no \"/\" or \":\"."),
                    "folderPath": string("Folder for the new note; \"\" for the library root. At most two levels."),
                    "tags": stringArray("Freeform tags for the new note."),
                ],
                required: ["kind", "title", "folderPath"]
            ),
        ]),
    ])

    // MARK: - Actions

    static let createNote = object(
        properties: [
            "action": constant("createNote"),
            "title": string("Title of the new note. Becomes the filename, so no \"/\" or \":\"."),
            "folderPath": string("Folder for the note; \"\" for the library root. At most two levels deep."),
            "content": string("Markdown body of the new note."),
            "tags": stringArray("Freeform tags."),
        ],
        required: ["action", "title", "folderPath", "content"],
        description: "Create a new note from session content."
    )

    static let appendToNote = object(
        properties: [
            "action": constant("appendToNote"),
            "target": noteRef,
            "content": string("Markdown to append. Existing content is never touched."),
            "heading": string("Optional heading placed above the appended block, without leading \"#\"."),
            "divider": boolean("Write a horizontal rule before the block. Defaults to true."),
        ],
        required: ["action", "target", "content"],
        description: "Append content to an existing note. Additive only."
    )

    static let createFolder = object(
        properties: [
            "action": constant("createFolder"),
            "path": string("New folder path, at most two levels, e.g. \"Commands\" or \"Commands/Docker\"."),
        ],
        required: ["action", "path"],
        description: "Create a Library folder. Prefer an existing folder over a new one."
    )

    static let moveNote = object(
        properties: [
            "action": constant("moveNote"),
            "note": noteRef,
            "toFolderPath": string("Destination folder; \"\" for the library root. At most two levels."),
        ],
        required: ["action", "note", "toFolderPath"],
        description: "Move a note to another folder."
    )

    static let retitleNote = object(
        properties: [
            "action": constant("retitleNote"),
            "note": noteRef,
            "newTitle": string("New title, which is also the new filename. No \"/\" or \":\"."),
        ],
        required: ["action", "note", "newTitle"],
        description: "Retitle a note — normally one the user left untitled."
    )

    static let tagNote = object(
        properties: [
            "action": constant("tagNote"),
            "note": noteRef,
            "tags": stringArray("Tags to add. Existing tags are kept."),
        ],
        required: ["action", "note", "tags"],
        description: "Add freeform tags to a note's metadata."
    )

    static let moveSegment = object(
        properties: [
            "action": constant("moveSegment"),
            "source": noteRef,
            "segment": string(
                "The exact text to move, copied byte-for-byte from the source note. "
                    + "If it does not match the note verbatim the whole plan is rejected."
            ),
            "segmentHash": string("Optional SHA-256 (lowercase hex) of \"segment\"."),
            "sourceRange": textRange,
            "destination": segmentDestination,
            "heading": string("Optional heading placed above the moved block, without leading \"#\"."),
            "divider": boolean("Write a horizontal rule before the block. Defaults to true."),
        ],
        required: ["action", "source", "segment", "destination"],
        description: """
        Merge: move a segment out of one note and into another in a single undoable step. \
        The segment text travels with the action so nothing can be lost.
        """
    )

    static let action = JSONValue.object([
        "description": "One action from the closed set.",
        "anyOf": .array([createNote, appendToNote, createFolder, moveNote, retitleNote, tagNote, moveSegment]),
    ])

    static let root = object(
        properties: [
            "summary": string(
                "One plain-language sentence for the user, e.g. \"Merge the curl snippet into Commands/curl\". "
                    + "No Markdown."
            ),
            "actions": .object([
                "type": "array",
                "description": "Zero or more actions. An empty list means nothing needs filing.",
                "items": action,
            ]),
        ],
        required: ["summary", "actions"]
    )
}
