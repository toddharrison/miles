import Foundation
import Testing
@testable import MilesCore

@Suite("Thumbnail generator")
struct ThumbnailGeneratorTests {
    final class CountingRenderer: ThumbnailRenderer, @unchecked Sendable {
        private let lock = NSLock()
        private var _paths: [String] = []
        var paths: [String] { lock.withLock { _paths } }
        func canRender(kind: String?) -> Bool { kind == "image" }
        func render(path: String, maxPixelSize: Int) throws -> Data {
            lock.withLock { _paths.append(path) }
            Thread.sleep(forTimeInterval: 0.05)
            return Data([1, 2, 3])
        }
    }

    @Test func rendersOnRequestAndOnlyOncePerFile() async throws {
        let env = try ScannerTests.Env(); defer { env.close() }
        env.fs.addFile("/Fake/photos/a.jpg", size: 10)
        try env.scan()
        let id = try #require(try env.library.files().first?.id)
        let renderer = CountingRenderer()
        let generator = ThumbnailGenerator(service: ThumbnailService(library: env.library, fileSystem: env.fs, renderer: renderer))

        // Six cells ask at once; the file is rendered a single time (once per cached size).
        let outcomes = await withTaskGroup(of: ThumbnailOutcome.self) { group in
            for _ in 0..<6 { group.addTask { await generator.ensure(fileID: id) } }
            return await group.reduce(into: []) { $0.append($1) }
        }
        #expect(outcomes.allSatisfy { $0 == .generated })
        let perRender = ThumbnailSize.allCases.count
        #expect(renderer.paths.count == perRender)
        #expect(FileManager.default.fileExists(atPath: env.library.thumbnailPath(fileID: id, size: .medium)))

        // Now it is cached: asking again renders nothing.
        #expect(await generator.ensure(fileID: id) == .upToDate)
        #expect(renderer.paths.count == perRender)
    }

    @Test func neverDownloadsAnEvictedFile() async throws {
        let env = try ScannerTests.Env(); defer { env.close() }
        env.fs.addFile("/Fake/photos/cloud.jpg", size: 10, dataless: true)
        try env.scan()
        let id = try #require(try env.library.files().first?.id)
        let renderer = CountingRenderer()
        let generator = ThumbnailGenerator(service: ThumbnailService(library: env.library, fileSystem: env.fs, renderer: renderer))
        #expect(await generator.ensure(fileID: id) == .notLocal)
        #expect(renderer.paths.isEmpty)
    }

    @Test func fillMissingCoversLocalImagesAndSkipsEvictedOnes() async throws {
        let env = try ScannerTests.Env(); defer { env.close() }
        env.fs.addFile("/Fake/photos/a.jpg", size: 10)
        env.fs.addFile("/Fake/photos/b.jpg", size: 10)
        env.fs.addFile("/Fake/photos/cloud.jpg", size: 10, dataless: true)
        try env.scan()
        let renderer = CountingRenderer()
        let generator = ThumbnailGenerator(service: ThumbnailService(library: env.library, fileSystem: env.fs, renderer: renderer))
        #expect(try await generator.fillMissing() == 2)
        #expect(try await generator.fillMissing() == 0, "a second pass finds nothing left to do")
    }
}
