import Foundation
@testable import MilesCore

/// A real temporary directory, resolved through symlinks, removed on `cleanup()`.
struct TempDir {
    let path: String

    init() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("miles-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        path = url.resolvingSymlinksInPath().path
    }

    func subdirectory(_ name: String) throws -> String {
        let p = path + "/" + name
        try FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
        return p
    }

    func cleanup() { try? FileManager.default.removeItem(atPath: path) }
}

func testOwner(host: String = "test-mac", pid: Int32 = 100, alive: @escaping @Sendable (Int32) -> Bool = { _ in true }) -> LockOwner {
    LockOwner(host: host, pid: pid, appVersion: "test", processIsAlive: alive)
}
