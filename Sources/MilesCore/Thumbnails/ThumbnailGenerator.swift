import Foundation

/// Makes thumbnails when something asks for them (a grid cell coming into view), one render per file at a time.
/// Asking again for a file that is already being rendered waits for that render instead of starting another.
/// Like `ThumbnailService.generate`, it never downloads an iCloud file (ADR 0011).
public actor ThumbnailGenerator {
    private let service: ThumbnailService
    private var inFlight: [Int64: Task<ThumbnailOutcome, Never>] = [:]

    public init(service: ThumbnailService) { self.service = service }

    /// Renders the file's thumbnails if they are missing or stale, off the caller's executor. Returns what happened.
    /// Nothing is rendered in advance: callers ask only for what is on screen.
    public func ensure(fileID: Int64) async -> ThumbnailOutcome {
        // A cell scrolled out of view cancels its request; do not start work nobody is waiting for.
        if Task.isCancelled { return .failed("cancelled") }
        if let running = inFlight[fileID] { return await running.value }
        let service = service
        let task = Task.detached(priority: .utility) { service.generate(fileID: fileID) }
        inFlight[fileID] = task
        let outcome = await task.value
        inFlight[fileID] = nil
        return outcome
    }
}
