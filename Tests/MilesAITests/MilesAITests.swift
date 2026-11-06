import Testing
@testable import MilesAI

@Suite("MilesAI module")
struct MilesAIModuleTests {
    @Test func identity() {
        #expect(MilesAI.name == "MilesAI")
    }
}
