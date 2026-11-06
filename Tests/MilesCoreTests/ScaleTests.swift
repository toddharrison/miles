import Foundation
import Testing
@testable import MilesCore

@Suite("Scale")
struct ScaleTests {
    func measure<T>(_ label: String, _ body: () throws -> T) rethrows -> (T, TimeInterval) {
        let start = Date()
        let value = try body()
        let elapsed = Date().timeIntervalSince(start)
        print("scale: \(label) took \(String(format: "%.1f", elapsed))s")
        return (value, elapsed)
    }

    func run(directories: Int, filesPerDirectory: Int, budget: TimeInterval) throws {
        let fs = SyntheticFileSystem(directories: directories, filesPerDirectory: filesPerDirectory)
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let lib = try Library.create(at: tmp.path + "/lib", fileSystem: RealFileSystem()); defer { try? lib.close() }
        let root = try lib.addRoot(at: "/Synth/root", fileSystem: fs, registry: LibraryRegistry(preferences: InMemoryPreferences()))
        let total = fs.totalFiles

        let (first, firstTime) = try measure("first scan of \(total) files") { try lib.scan(rootID: root.id, fileSystem: fs) }
        #expect(first.added == total)
        #expect(try lib.fileCount() == total)
        #expect(firstTime < budget, "first scan took \(firstTime)s")

        let (again, againTime) = try measure("unchanged rescan") { try lib.scan(rootID: root.id, fileSystem: fs) }
        #expect(again.unchanged == total && again.added == 0 && again.updated == 0 && again.markedMissing == 0)
        #expect(againTime < budget, "rescan took \(againTime)s")

        // One directory vanishes: only its files are marked missing, and quickly.
        fs.removeDirectory(7)
        let (partial, partialTime) = try measure("rescan after one directory vanished") { try lib.scan(rootID: root.id, fileSystem: fs) }
        #expect(partial.markedMissing == filesPerDirectory)
        #expect(try lib.fileCount() == total - filesPerDirectory)
        #expect(partialTime < budget)

        // A scoped scan is cheap whatever the size of the root.
        let (_, scopedTime) = try measure("subtree scan of one directory") { try lib.scan(rootID: root.id, scope: .subtree("d9"), fileSystem: fs) }
        #expect(scopedTime < 5)

        // Listing a page is fast too.
        let (page, pageTime) = try measure("list first 100") { try lib.files(rootID: root.id, limit: 100) }
        #expect(page.count == 100)
        #expect(pageTime < 1)
    }

    /// Always on: big enough to catch accidental quadratic behaviour.
    @Test func fiftyThousandFiles() throws {
        try run(directories: 50, filesPerDirectory: 1000, budget: 30)
    }

    /// The Step 1 acceptance test. A million files; set MILES_SCALE_TESTS=1 to run it (it takes a while).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MILES_SCALE_TESTS"] != nil))
    func millionFiles() throws {
        try run(directories: 1000, filesPerDirectory: 1000, budget: 600)
    }
}
