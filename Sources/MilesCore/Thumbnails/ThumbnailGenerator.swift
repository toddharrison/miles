import Foundation

/// Makes thumbnails when something asks for them (a grid cell coming into view), one render per file at a time.
/// Asking again for a file that is already being rendered waits for that render instead of starting another.
/// Like `ThumbnailService.generate`, it never downloads an iCloud file (ADR 0011).
public actor ThumbnailGenerator {
    private let service: ThumbnailService
    private var inFlight: [Int64: Task<ThumbnailOutcome, Never>] = [:]

    public init(service: ThumbnailService) { self.service = service }

    /// Renders the file's thumbnails if they are missing or stale, off the caller's executor. Returns what happened.
    public func ensure(fileID: Int64) async -> ThumbnailOutcome {
        if let running = inFlight[fileID] { return await running.value }
        let service = service
        let task = Task.detached(priority: .utility) { service.generate(fileID: fileID) }
        inFlight[fileID] = task
        let outcome = await task.value
        inFlight[fileID] = nil
        return outcome
    }

    /// Works through every local image that has no current thumbnail, so files never scrolled into view are covered
    /// before they might be evicted. Stops early if the task is cancelled. `progress` gets (done, total).
    @discardableResult
    public func fillMissing(progress: (@Sendable (Int, Int) -> Void)? = nil) async throws -> Int {
        let ids = try service.library.filesNeedingThumbnails(rootID: nil, limit: nil)
        var generated = 0
        for (index, id) in ids.enumerated() {
            if Task.isCancelled { break }
            progress?(index, ids.count)
            if await ensure(fileID: id) == .generated { generated += 1 }
        }
        progress?(ids.count, ids.count)
        return generated
    }
}
