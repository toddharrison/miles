import Foundation
import Testing
@testable import MilesCore

@Suite("Library lock")
struct LibraryLockTests {
    func makeFS() throws -> FakeFileSystem {
        let fs = FakeFileSystem()
        try fs.createDirectory(at: "/lib")
        return fs
    }

    @Test func secondOpenerIsRefusedWhileFirstIsAlive() throws {
        let fs = try makeFS()
        let first = try LibraryLock.acquire(directory: "/lib", fileSystem: fs, owner: testOwner(pid: 1))
        defer { first.release() }
        do {
            _ = try LibraryLock.acquire(directory: "/lib", fileSystem: fs, owner: testOwner(pid: 2))
            Issue.record("expected the lock to be refused")
        } catch let LibraryError.locked(holder, staleness) {
            #expect(holder?.pid == 1)
            #expect(staleness == .live)
        }
    }

    @Test func releaseFreesTheLock() throws {
        let fs = try makeFS()
        let first = try LibraryLock.acquire(directory: "/lib", fileSystem: fs, owner: testOwner(pid: 1))
        first.release()
        first.release() // idempotent
        #expect(!fs.exists("/lib/lock.json"))
        _ = try LibraryLock.acquire(directory: "/lib", fileSystem: fs, owner: testOwner(pid: 2))
    }

    @Test func staleLockOnThisMacIsReclaimedAutomatically() throws {
        let fs = try makeFS()
        let crashed = try LibraryLock.acquire(directory: "/lib", fileSystem: fs, owner: testOwner(pid: 1))
        // Simulate the crash: the file stays, the process is gone.
        let deadOwner = testOwner(pid: 2, alive: { $0 != 1 })
        let taken = try LibraryLock.acquire(directory: "/lib", fileSystem: fs, owner: deadOwner)
        #expect(taken.info.pid == 2)
        withExtendedLifetime(crashed) {}
    }

    @Test func lockFromAnotherMacNeedsExplicitTakeover() throws {
        let fs = try makeFS()
        let held = try LibraryLock.acquire(directory: "/lib", fileSystem: fs, owner: testOwner(host: "other-mac", pid: 7))
        defer { held.release() }

        do {
            _ = try LibraryLock.acquire(directory: "/lib", fileSystem: fs, owner: testOwner(host: "this-mac", pid: 1))
            Issue.record("expected the lock to be refused")
        } catch let LibraryError.locked(holder, staleness) {
            #expect(holder?.host == "other-mac")
            #expect(staleness == .unknown)
        }

        let taken = try LibraryLock.acquire(directory: "/lib", fileSystem: fs, owner: testOwner(host: "this-mac", pid: 1), takeOver: true)
        #expect(taken.info.host == "this-mac")
    }

    @Test func liveLockCanStillBeTakenOverWhenUserInsists() throws {
        let fs = try makeFS()
        let held = try LibraryLock.acquire(directory: "/lib", fileSystem: fs, owner: testOwner(pid: 1))
        defer { held.release() }
        let taken = try LibraryLock.acquire(directory: "/lib", fileSystem: fs, owner: testOwner(pid: 2), takeOver: true)
        #expect(taken.info.pid == 2)
    }

    @Test func releasingAfterTakeoverDoesNotRemoveTheNewHoldersLock() throws {
        let fs = try makeFS()
        let old = try LibraryLock.acquire(directory: "/lib", fileSystem: fs, owner: testOwner(pid: 1))
        let new = try LibraryLock.acquire(directory: "/lib", fileSystem: fs, owner: testOwner(pid: 2), takeOver: true)
        old.release()
        #expect(fs.exists("/lib/lock.json"))
        new.release()
        #expect(!fs.exists("/lib/lock.json"))
    }

    @Test func unreadableLockIsUnknownAndNeedsTakeover() throws {
        let fs = try makeFS()
        try fs.writeFile(Data("garbage".utf8), to: "/lib/lock.json")
        #expect(throws: LibraryError.locked(holder: nil, staleness: .unknown)) {
            _ = try LibraryLock.acquire(directory: "/lib", fileSystem: fs, owner: testOwner())
        }
        _ = try LibraryLock.acquire(directory: "/lib", fileSystem: fs, owner: testOwner(), takeOver: true)
    }

    @Test func inspectReportsHolderWithoutTaking() throws {
        let fs = try makeFS()
        #expect(LibraryLock.inspect(directory: "/lib", fileSystem: fs, owner: testOwner()) == nil)
        let held = try LibraryLock.acquire(directory: "/lib", fileSystem: fs, owner: testOwner(pid: 1))
        defer { held.release() }
        let seen = LibraryLock.inspect(directory: "/lib", fileSystem: fs, owner: testOwner(pid: 2))
        #expect(seen?.holder?.pid == 1)
        #expect(seen?.staleness == .live)
    }
}
