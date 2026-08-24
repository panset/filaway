import Foundation
import Testing

@testable import FilawayCore

@Suite("Exclusion filter (FR-4.5)")
struct ExclusionFilterTests {
    private let filter = ExclusionFilter(excludedFolders: ["Private", "Work/Confidential"])

    @Test("exclusion matches on folder boundaries only")
    func boundaries() {
        #expect(filter.isExcluded(path: "Private"))
        #expect(filter.isExcluded(path: "Private/Salary.md"))
        #expect(filter.isExcluded(path: "Private/Deep/Deeper.md"))
        #expect(filter.isExcluded(path: "Work/Confidential/plan.md"))
        #expect(!filter.isExcluded(path: "Private notes/ok.md"), "a prefix is not a folder")
        #expect(!filter.isExcluded(path: "PrivateStuff.md"))
        #expect(!filter.isExcluded(path: "Work/Public/plan.md"))
        #expect(!filter.isExcluded(path: ""), "the library root is never excluded wholesale")
        #expect(ExclusionFilter.none.isExcluded(path: "anything") == false)
    }

    @Test("the folder list is normalised and de-duplicated")
    func normalisation() {
        let messy = ExclusionFilter(excludedFolders: ["/Private/", "Private", "", "Work//Confidential", "."])
        #expect(messy.excludedFolders == ["Private", "Work/Confidential"])
        #expect(messy.isExcluded(path: "Private/x.md"))
    }

    @Test("a snapshot loses its excluded notes and folders")
    func filtersSnapshot() {
        let filtered = ExclusionFilter(excludedFolders: ["Private"]).filter(SampleLibrary.snapshot)
        #expect(!filtered.notes.contains { $0.relativePath.hasPrefix("Private/") })
        #expect(filtered.notes.count == SampleLibrary.notes.count - 1)
        #expect(!filtered.folderPaths.contains("Private"))
        #expect(filtered.folderPaths == ["Commands"])
    }

    @Test("the organizer's context never contains an excluded note")
    func contextIsFiltered() {
        let context = SampleLibrary.context
        #expect(context.note(id: SampleLibrary.privateID) == nil)
        #expect(context.note(path: "Private/Salary.md") == nil)
        #expect(context.bodies[SampleLibrary.privateID] == nil, "not even the body map")
        #expect(context.excludedFolders == ["Private"], "the path is still known, so targets can be rejected")
        #expect(context.isExcluded("Private/Salary.md"))
        #expect(!context.folderExists("Private"))
    }

    @Test("no excluded text survives into a request built from the context")
    func nothingLeaksIntoARequest() throws {
        let context = SampleLibrary.context
        var lines = ["Folders: \(context.folderPaths.joined(separator: ", "))"]
        for note in context.notes {
            lines.append("- \(note.relativePath)")
            lines.append(context.bodies[note.id] ?? "")
        }
        let request = AIRequest(
            model: .defaultOrganize,
            purpose: .organize,
            system: "You file notes.",
            messages: [.user(lines.joined(separator: "\n"))],
            tools: [OrganizationPlan.tool],
            toolChoice: .tool(name: OrganizationPlan.toolName)
        )
        let body = ClaudeWire.body(for: request)
        let leaks = ExclusionFilter(excludedFolders: ["Private"])
            .leaks(in: body, bodies: SampleLibrary.bodies, notes: SampleLibrary.notes)
        #expect(leaks.isEmpty, "\(leaks)")

        let text = body.allStrings.joined(separator: "\n")
        #expect(text.contains("Commands/curl.md"), "the allowed notes are still there")
        #expect(!text.contains("Salary"))
        #expect(!text.contains("12345"))
    }

    @Test("the leak detector actually detects a leak")
    func detectorWorks() {
        let leaky = JSONValue.object(["messages": .array([.string(SampleLibrary.privateBody)])])
        let leaks = ExclusionFilter(excludedFolders: ["Private"])
            .leaks(in: leaky, bodies: SampleLibrary.bodies, notes: SampleLibrary.notes)
        #expect(leaks == ["Private/Salary.md"])
    }

    @Test("excluded and allowed partition the library")
    func partition() {
        let allowed = filter.allowed(SampleLibrary.notes)
        let excluded = filter.excluded(SampleLibrary.notes)
        #expect(allowed.count + excluded.count == SampleLibrary.notes.count)
        #expect(Set(allowed.map(\.id)).isDisjoint(with: Set(excluded.map(\.id))))
        #expect(excluded.map(\.relativePath) == ["Private/Salary.md"])
    }

    @Test("bodies are filtered by note id, not by path")
    func filtersBodies() {
        let bodies = filter.filter(bodies: SampleLibrary.bodies, notes: SampleLibrary.notes)
        #expect(bodies[SampleLibrary.privateID] == nil)
        #expect(bodies[SampleLibrary.curlID] != nil)
    }
}

@Suite("Organize context")
struct OrganizeContextTests {
    @Test("references resolve by id and by path")
    func resolution() {
        let context = SampleLibrary.openContext
        #expect(context.note(for: .id(SampleLibrary.curlID))?.relativePath == "Commands/curl.md")
        #expect(context.note(for: .path("Commands/curl.md"))?.id == SampleLibrary.curlID)
        #expect(context.note(for: NoteRef(id: SampleLibrary.curlID, path: "Commands/curl.md")) != nil)
        #expect(context.note(for: NoteRef()) == nil)
        #expect(context.referenceIsContradictory(NoteRef(id: SampleLibrary.curlID, path: "Scratch.md")))
        #expect(!context.referenceIsContradictory(NoteRef(id: SampleLibrary.curlID, path: "Commands/curl.md")))
    }

    @Test("preconditions cover exactly the notes a plan touches")
    func preconditions() {
        let context = SampleLibrary.openContext
        let plan = OrganizationPlan(summary: "s", actions: [
            .tagNote(TagNoteAction(note: .id(SampleLibrary.curlID), tags: ["x"])),
            .createNote(CreateNoteAction(title: "New", folderPath: "", content: "x")),
        ])
        let preconditions = context.preconditions(for: plan)
        #expect(preconditions.noteIDs == [SampleLibrary.curlID])
        #expect(preconditions[SampleLibrary.curlID] == SampleLibrary.precondition(for: SampleLibrary.curlID))
    }

    @Test("folder existence knows the root and the tree")
    func folders() {
        let context = SampleLibrary.openContext
        #expect(context.folderExists(""))
        #expect(context.folderExists("Commands"))
        #expect(!context.folderExists("Nope"))
    }
}
