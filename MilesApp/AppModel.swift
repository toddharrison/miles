import AppKit
import MilesCore
import Observation

/// App state: the open library, its roots, the current search and the results shown in the grid.
/// All database and filesystem work runs off the main actor; this class only publishes results.
@MainActor @Observable
final class AppModel {
    let fileSystem = RealFileSystem()
    let registry = LibraryRegistry(preferences: UserDefaultsPreferences(UserDefaults(suiteName: "app.miles.Miles") ?? .standard))

    private(set) var library: Library?
    /// Background tagging (layers 1 and 2). Throttled; waits on battery power or a busy Mac (ADR 0003).
    private var jobQueue: JobQueue?
    private(set) var libraryName: String?
    private(set) var libraries: [LibraryRecord] = []
    private(set) var roots: [RootRecord] = []
    private(set) var files: [IndexedFile] = []
    private(set) var totalFiles = 0
    /// Bumped whenever thumbnails may have changed, so the grid drops its in-memory images.
    private(set) var thumbnailGeneration = 0
    private(set) var status: String?
    /// A fetch-once batch that is large enough to need the user's approval (ADR 0011).
    var pendingFetch: FetchPlan?
    var errorMessage: String?

    var selectedRootID: Int64? { didSet { if oldValue != selectedRootID { refresh() } } }
    var query = ""

    nonisolated private static let resultLimit = 50_000

    init() {
        libraries = registry.libraries
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.closeLibrary() }
        }
        if let id = registry.defaultLibraryID { openLibrary(id) }
    }

    // MARK: Libraries

    func openLibrary(_ id: UUID) {
        closeLibrary()
        do {
            let opened = try registry.open(id, fileSystem: fileSystem)
            library = opened
            libraryName = registry.libraries.first { $0.id == id }?.name
            try? registry.setDefault(id)
            selectedRootID = nil
            reloadRoots()
            refresh()
            runScheduledBackup()
            startJobQueue(for: opened)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Takes the daily snapshot of Miles' own data when one is due (ADR 0005). A failed backup is shown, not swallowed.
    private func runScheduledBackup() {
        guard let library else { return }
        Task {
            let error = await Task.detached { () -> String? in
                do { _ = try library.runScheduledBackupIfDue(); return nil }
                catch { return "Backup failed: \(error.localizedDescription)" }
            }.value
            if let error, self.library === library { errorMessage = error }
        }
    }

    func createLibrary() {
        let panel = NSSavePanel()
        panel.title = "New Miles Library"
        panel.message = "Choose where to keep the library folder. It must be on a local disk, not in iCloud."
        panel.nameFieldStringValue = "Miles Library"
        panel.prompt = "Create"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        closeLibrary()
        do {
            let created = try Library.create(at: url.path, fileSystem: fileSystem)
            registry.register(created, name: url.lastPathComponent)
            try? registry.setDefault(created.id)
            library = created
            libraryName = url.lastPathComponent
            libraries = registry.libraries
            selectedRootID = nil
            reloadRoots()
            refresh()
            startJobQueue(for: created)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Queues whatever tagging is due, then works through it in the background.
    private func startJobQueue(for library: Library) {
        let queue = JobQueue(library: library, handlers: library.taggingHandlers(fileSystem: fileSystem))
        jobQueue = queue
        let fs = fileSystem
        Task.detached {
            _ = try? library.recoverInterruptedOperations(fileSystem: fs)
            _ = try? library.enqueueDueJobs()
            queue.start()
        }
    }

    func closeLibrary() {
        jobQueue?.stop()
        jobQueue = nil
        try? library?.close()
        library = nil
        roots = []
        files = []
        totalFiles = 0
    }

    // MARK: Roots

    func addRoot() {
        guard let library else { return }
        let panel = NSOpenPanel()
        panel.title = "Add Folder"
        panel.message = "Miles indexes the folder in place. It never moves or changes your files."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Add"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try library.addRoot(at: url.path, fileSystem: fileSystem, registry: registry)
            reloadRoots()
            scan()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func removeRoot(_ id: Int64) {
        guard let library else { return }
        do {
            try library.removeRoot(id: id)
            if selectedRootID == id { selectedRootID = nil }
            reloadRoots()
            refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setFetchOnce(_ enabled: Bool, root id: Int64) {
        do {
            try library?.setFetchOnce(enabled, forRoot: id)
            reloadRoots()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func reloadRoots() {
        roots = (try? library?.roots()) ?? []
        libraries = registry.libraries
    }

    // MARK: Scan and thumbnails

    /// Scans every root, builds thumbnails for local images (never downloading), then runs any
    /// opted-in fetch-once roots. Large fetch batches wait for approval in `pendingFetch`.
    func scan() {
        guard let library else { return }
        status = "Scanning…"
        let fs = fileSystem
        let ids = roots.map(\.id)
        Task {
            let outcome = await Task.detached { () -> (pending: FetchPlan?, error: String?) in
                var pending: FetchPlan?
                do {
                    for id in ids { try library.scan(rootID: id, fileSystem: fs) }
                    try library.enqueueDueJobs()
                    let service = ThumbnailService(library: library, fileSystem: fs)
                    _ = try service.generateMissing()
                    for root in try library.roots() where root.fetchOnce {
                        do { _ = try service.fetchOnce(rootID: root.id) }
                        catch let ThumbnailError.needsApproval(plan) { pending = pending ?? plan }
                    }
                    return (pending, nil)
                } catch {
                    return (pending, error.localizedDescription)
                }
            }.value
            guard self.library === library else { return }
            status = nil
            errorMessage = outcome.error
            pendingFetch = outcome.pending
            thumbnailGeneration += 1
            reloadRoots()
            refresh()
        }
    }

    func approvePendingFetch() {
        guard let library, let plan = pendingFetch else { return }
        pendingFetch = nil
        status = "Fetching \(plan.fileCount) files for thumbnails…"
        let fs = fileSystem
        Task {
            let error = await Task.detached { () -> String? in
                do { _ = try ThumbnailService(library: library, fileSystem: fs).fetchOnce(rootID: plan.rootID, approvedCount: plan.fileCount); return nil }
                catch { return error.localizedDescription }
            }.value
            guard self.library === library else { return }
            status = nil
            errorMessage = error
            thumbnailGeneration += 1
        }
    }

    // MARK: Search

    /// Runs the search box text. A malformed query shows its parse error; there is no loose-text fallback (ADR 0009).
    func refresh() {
        guard let library else { return }
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let rootID = selectedRootID
        Task {
            let result = await Task.detached { () -> Result<([IndexedFile], Int), Error> in
                Result {
                    let found = text.isEmpty
                        ? try library.files(rootID: rootID, limit: Self.resultLimit)
                        : try library.search(text, limit: Self.resultLimit).filter { rootID == nil || $0.rootID == rootID }
                    return (found, try library.fileCount())
                }
            }.value
            guard self.library === library, text == query.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
            switch result {
            case .success(let (found, total)):
                files = found
                totalFiles = total
                errorMessage = nil
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: Files

    func thumbnailPath(for fileID: Int64) -> String {
        library?.thumbnailPath(fileID: fileID, size: .medium) ?? ""
    }

    /// Opens a file on the user's action. An evicted iCloud file is downloaded first (ADR 0011).
    func open(_ file: IndexedFile) {
        guard let library else { return }
        let placeholder = file.icloudStatus == "dataless"
        if placeholder { status = "Downloading \((file.relativePath as NSString).lastPathComponent)…" }
        let fs = fileSystem
        Task {
            let result = await Task.detached { () -> Result<String, Error> in
                Result { try ThumbnailService(library: library, fileSystem: fs).prepareToOpen(fileID: file.id) }
            }.value
            guard self.library === library else { return }
            status = nil
            switch result {
            case .success(let path):
                NSWorkspace.shared.open(URL(fileURLWithPath: path))
                if placeholder { thumbnailGeneration += 1; refresh() }
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
    }
}
