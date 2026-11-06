import AppKit
import MilesAI
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
    /// Looks for new AI suggestions while the background queue works.
    private var suggestionPoll: Task<Void, Never>?
    private(set) var libraryName: String?
    private(set) var libraries: [LibraryRecord] = []
    private(set) var roots: [RootRecord] = []
    private(set) var files: [IndexedFile] = []
    private(set) var totalFiles = 0
    /// Bumped whenever thumbnails may have changed, so the grid drops its in-memory images.
    private(set) var thumbnailGeneration = 0
    private(set) var status: String?
    /// Fraction done (0...1) of the current scan step, or nil when the work has no known total.
    private(set) var progress: Double?
    /// On-device AI providers (ADR 0003, 0015). Which are usable is decided when the queue starts.
    let ai = AIPipeline()
    /// AI suggestions waiting for the user (ADR 0010).
    private(set) var suggestionCount = 0
    private(set) var suggestions: [Suggestion] = []
    /// What the on-device model wrote for the last plain-language search, shown for the user to check before it runs (ADR 0015).
    var translation: QueryTranslation?
    private(set) var translating = false
    /// A fetch-once batch that is large enough to need the user's approval (ADR 0011).
    var pendingFetch: FetchPlan?
    var errorMessage: String?
    /// Why the wanted library is not open (drive not connected, locked, newer schema), shown in place of the grid (ADR 0012).
    private(set) var unavailable: (libraryName: String, availability: LibraryAvailability)?
    /// A lock Miles cannot show to be dead. Opening waits for the user's explicit confirmation.
    var pendingTakeOver: LibraryRecord?
    /// The library the user wants open; retried when a drive mounts.
    private var wantedLibraryID: UUID?

    var selectedRootID: Int64? { didSet { if oldValue != selectedRootID { refresh() } } }
    var query = ""

    nonisolated private static let resultLimit = 50_000

    init() {
        libraries = registry.libraries
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.closeLibrary() }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.driveMounted() }
        }
        workspace.addObserver(forName: NSWorkspace.willUnmountNotification, object: nil, queue: .main) { [weak self] note in
            let device = note.userInfo?["NSDevicePath"] as? String
            MainActor.assumeIsolated { self?.driveWillUnmount(devicePath: device) }
        }
        if let id = registry.defaultLibraryID { openLibrary(id) }
    }

    /// A drive appeared: reopen the wanted library if that is what was missing, and rescan roots that came back.
    private func driveMounted() {
        if library == nil, let id = wantedLibraryID, unavailable?.availability == .driveNotMounted {
            openLibrary(id)
        } else if library != nil {
            reloadRoots()
            if roots.contains(where: { $0.location.resolve(fileSystem: fileSystem) != nil }) { scan() }
        }
    }

    /// The library's own drive is being ejected: close it first so the database and lock are left clean on the drive.
    private func driveWillUnmount(devicePath: String?) {
        guard let library, let url = devicePath,
              library.directory == url || library.directory.hasPrefix(url + "/") else { return }
        let name = libraryName ?? "Library"
        closeLibrary()
        unavailable = (name, .driveNotMounted)
    }

    // MARK: Libraries

    /// Opens a library, or says why it cannot be. `takeOver` is only passed after the user confirmed a lock.
    func openLibrary(_ id: UUID, takeOver: Bool = false) {
        closeLibrary()
        wantedLibraryID = id
        unavailable = nil
        if let record = registry.libraries.first(where: { $0.id == id }) {
            let availability = registry.availability(of: record, fileSystem: fileSystem)
            if !availability.canOpen && !(takeOver && availability.needsTakeOverConfirmation) {
                unavailable = (record.name, availability)
                libraryName = record.name
                if availability.needsTakeOverConfirmation { pendingTakeOver = record }
                return
            }
        }
        do {
            let opened = try registry.open(id, fileSystem: fileSystem, takeOverLock: takeOver)
            library = opened
            libraryName = registry.libraries.first { $0.id == id }?.name
            try? registry.setDefault(id)
            selectedRootID = nil
            opened.removeObsoleteThumbnailSizes()
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
        let fs = fileSystem
        let ai = ai
        Task {
            // Only layers with a usable provider get handlers and jobs; layer 4 also needs a root that turned it on.
            let handlers = await ai.allHandlers(library: library, fileSystem: fs)
            let versions = await ai.layerVersions()
            guard self.library === library else { return }
            let queue = JobQueue(library: library, handlers: handlers)
            jobQueue = queue
            Task.detached {
                _ = try? library.recoverInterruptedOperations(fileSystem: fs)
                // Originals past the retention the user set go to the Trash. Only Miles' own holdback copies are touched.
                _ = try? library.releaseExpiredHoldbacks(fileSystem: fs)
                _ = try? library.enqueueDueJobs(ai: versions)
                queue.start()
            }
        }
        reloadSuggestions()
        suggestionPoll?.cancel()
        suggestionPoll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                self?.reloadSuggestions()
            }
        }
    }

    func retryWanted() {
        if let id = wantedLibraryID { openLibrary(id) }
    }

    func confirmTakeOver() {
        guard let record = pendingTakeOver else { return }
        pendingTakeOver = nil
        openLibrary(record.id, takeOver: true)
    }

    func closeLibrary() {
        suggestionPoll?.cancel()
        suggestionPoll = nil
        jobQueue?.stop()
        jobQueue = nil
        try? library?.close()
        library = nil
        roots = []
        files = []
        totalFiles = 0
        suggestions = []
        suggestionCount = 0
        translation = nil
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

    /// Layer 4 (LLM/VLM) is off by default; this turns it on for images and text in one root, or off again (ADR 0010).
    func setLayer4(_ enabled: Bool, root id: Int64) {
        do {
            try library?.setLayer4Kinds(enabled ? [.image, .text] : [], forRoot: id)
            reloadRoots()
            if enabled { queueAIWork() }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setAutoAccept(_ threshold: Double?, root id: Int64) {
        do {
            try library?.setAutoAcceptThreshold(threshold, forRoot: id)
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
        guard let library, status == nil else { return }
        status = "Scanning…"
        let fs = fileSystem
        let ids = roots.map(\.id)
        let ai = ai
        progress = nil
        let report: @Sendable (String, Double?) -> Void = { [weak self] text, fraction in
            Task { @MainActor in
                guard let self, self.status != nil else { return }
                self.status = text
                self.progress = fraction
            }
        }
        Task {
            let versions = await ai.layerVersions()
            let outcome = await Task.detached { () -> (pending: FetchPlan?, error: String?) in
                var pending: FetchPlan?
                do {
                    for (n, id) in ids.enumerated() {
                        let folder = ids.count > 1 ? " (folder \(n + 1) of \(ids.count))" : ""
                        report("Scanning\(folder)…", nil)
                        let options = ScanOptions(progress: { count in report("Scanning\(folder): \(count.formatted()) files indexed", nil) })
                        try library.scan(rootID: id, fileSystem: fs, options: options)
                    }
                    report("Queuing background work…", nil)
                    try library.enqueueDueJobs(ai: versions)
                    let service = ThumbnailService(library: library, fileSystem: fs)
                    _ = try service.generateMissing(progress: { done, total in
                        report("Making thumbnails: \(done.formatted()) of \(total.formatted())", total == 0 ? nil : Double(done) / Double(total))
                    })
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
            progress = nil
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

    // MARK: AI suggestions and plain-language search

    /// Queues AI work that is due (for example after layer 4 was turned on for a root). The queue picks it up.
    private func queueAIWork() {
        guard let library else { return }
        let ai = ai
        Task {
            let versions = await ai.layerVersions()
            await Task.detached { _ = try? library.enqueueDueJobs(ai: versions) }.value
        }
    }

    func reloadSuggestions() {
        guard let library else { return }
        Task {
            let result = await Task.detached { () -> ([Suggestion], Int)? in
                guard let list = try? library.reviewQueue(limit: 500), let count = try? library.suggestionCount() else { return nil }
                return (list, count)
            }.value
            guard self.library === library, let (list, count) = result else { return }
            suggestions = list
            suggestionCount = count
        }
    }

    func decide(_ suggestion: Suggestion, accept: Bool) {
        guard let library else { return }
        do {
            if accept { try library.acceptSuggestion(fileID: suggestion.fileID, tag: suggestion.tag) }
            else { try library.rejectSuggestion(fileID: suggestion.fileID, tag: suggestion.tag) }
            suggestions.removeAll { $0.id == suggestion.id }
            suggestionCount = max(suggestionCount - 1, 0)
            if accept { refresh() }
        } catch {
            errorMessage = error.localizedDescription
            reloadSuggestions()
        }
    }

    func acceptAll(minConfidence: Double) {
        do {
            _ = try library?.acceptSuggestions(minConfidence: minConfidence)
            reloadSuggestions()
            refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Asks the on-device model for a query. Nothing runs until the user accepts the query shown (`runTranslation`).
    func translate(_ request: String) {
        guard let library, !request.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        translating = true
        translation = nil
        let ai = ai
        Task {
            let result = await Task.detached { () -> Result<QueryTranslation, Error> in
                do { return .success(try await QueryTranslator(provider: ai.translator).translate(request, in: library)) }
                catch { return .failure(error) }
            }.value
            guard self.library === library else { return }
            translating = false
            switch result {
            case .success(let t): translation = t
            case .failure(let error): errorMessage = error.localizedDescription
            }
        }
    }

    /// Runs the translated query (as the user may have edited it) in the search box.
    func runTranslation(_ edited: String) {
        query = edited
        translation = nil
        refresh()
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
