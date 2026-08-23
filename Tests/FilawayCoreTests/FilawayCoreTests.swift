import Testing

@testable import FilawayCore

@Test("Core exposes a version and the shared OSLog subsystem")
func coreMetadata() {
    #expect(FilawayCore.version == "0.1.0")
    #expect(FilawayCore.subsystem == "com.tejaspanse.filaway")
}
