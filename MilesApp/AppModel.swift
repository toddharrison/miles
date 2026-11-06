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
    /// A library the user asked to delete, waiting for them to choose what happens to its folder.
    var pendingLibraryDeletion: LibraryRecord?
    /// The library the user wants open; retried when a drive mounts.
    private var wantedLibraryID: UUID?

    var selectedRootID: Int64? { didSet { if oldValue != selectedRootID { refresh() } } }
    var query = "" {
        didSet { if let saved = activeSaved, saved.query != query { activeSaved = nil } }
    }
    /// The saved search whose query is in the search box, so the sidebar can highlight it. Editing the text clears it.
    private(set) var activeSaved: SavedSearch?
    private(set) var savedSearches: [SavedSearch] = []
    /// The parser's message for the query in the search box, shown inline. The grid keeps the last good results.
    private(set) var queryError: String?
    private(set) var searchHistory: [String] = UserDefaults(suiteName: "app.miles.Miles")?.stringArray(forKey: "searchHistory") ?? []

    // Selection, tags and the tag browser
    var selectedFileIDs: Set<Int64> = [] {
        didSet { if oldValue != selectedFileIDs { loadSelectionTags() } }
    }
    private(set) var selectionTags: [SelectionTag] = []
    /// False when too many files are selected to list their tags one by one.
    private(set) var selectionTagsListed = true
    private(set) var tagBusy = false
    /// Every tag with its file count: the tag browser and autocomplete.
    private(set) var allTags: [TagInfo] = []

    // Background work
    private(set) var waitingJobs: [JobGroup: Int] = [:]
    private(set) var queuePaused = false
    private var statusPoll: Task<Void, Never>?
    let quickLook = QuickLook()

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
            reloadSavedSearches()
            reloadTags()
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
            reloadSavedSearches()
            reloadTags()
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
            queuePaused = false
            Task.detached {
                _ = try? library.recoverInterruptedOperations(fileSystem: fs)
                // Originals past the retention the user set go to the Trash. Only Miles' own holdback copies are touched.
                _ = try? library.releaseExpiredHoldbacks(fileSystem: fs)
                _ = try? library.enqueueDueJobs(ai: versions)
                queue.start()
            }
        }
        reloadSuggestions()
        statusPoll?.cancel()
        statusPoll = Task { [weak self] in
            while !Task.isCancelled {
                await self?.reloadWaitingJobs()
                try? await Task.sleep(for: .seconds(3))
            }
        }
        suggestionPoll?.cancel()
        suggestionPoll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                self?.reloadSuggestions()
            }
        }
    }

    /// Deletes a library the user chose. Only Miles' own library folder (index, tags, backups) can go, and only to the
    /// Trash. Indexed files are never touched. Anything that fails leaves the library registered.
    func deleteLibrary(_ record: LibraryRecord, moveFolderToTrash: Bool) {
        pendingLibraryDeletion = nil
        let wasOpen = library?.id == record.id || wantedLibraryID == record.id
        if wasOpen {
            closeLibrary()
            wantedLibraryID = nil
            unavailable = nil
            libraryName = nil
        }
        if moveFolderToTrash {
            guard let path = registry.path(of: record, fileSystem: fileSystem) else {
                errorMessage = "\(record.name) is on a drive that is not connected, so its folder cannot be moved to the Trash. Connect the drive, or remove it from the list only."
                return
            }
            do { _ = try fileSystem.trash(at: path) }
            catch {
                errorMessage = "Could not move \(record.name) to the Trash: \(error.localizedDescription)"
                return
            }
        }
        registry.unregister(record.id)
        libraries = registry.libraries
        if wasOpen, let next = registry.defaultLibraryID { openLibrary(next) }
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
        statusPoll?.cancel()
        statusPoll = nil
        quickLook.close()
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
        selectedFileIDs = []
        selectionTags = []
        allTags = []
        savedSearches = []
        activeSaved = nil
        queryError = nil
        waitingJobs = [:]
        queuePaused = false
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

    /// Runs the search box text. A malformed query shows its parse error inline; there is no loose-text fallback (ADR 0009).
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
                queryError = nil
                let present = Set(found.map(\.id))
                if !selectedFileIDs.isSubset(of: present) { selectedFileIDs.formIntersection(present) }
                if !text.isEmpty { remember(text) }
            case .failure(let error):
                // A query the parser refused is the user's to fix, so it is shown by the search box, not as an alert.
                if error is QueryError { queryError = error.localizedDescription }
                else { errorMessage = error.localizedDescription }
            }
        }
    }

    private func remember(_ text: String) {
        guard searchHistory.first != text else { return }
        searchHistory = Array(([text] + searchHistory.filter { $0 != text }).prefix(15))
        UserDefaults(suiteName: "app.miles.Miles")?.set(searchHistory, forKey: "searchHistory")
    }

    // MARK: Saved searches and the tag browser

    func reloadSavedSearches() {
        savedSearches = (try? library?.savedSearches()) ?? []
    }

    func saveCurrentSearch(named name: String) {
        guard let library else { return }
        do {
            activeSaved = try library.saveSearch(name: name, query: query.trimmingCharacters(in: .whitespacesAndNewlines))
            reloadSavedSearches()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteSavedSearch(_ saved: SavedSearch) {
        do {
            try library?.deleteSavedSearch(name: saved.name)
            if activeSaved?.id == saved.id { activeSaved = nil }
            reloadSavedSearches()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Runs a saved search from the sidebar. It searches all folders; the stored query may name a root itself.
    func run(_ saved: SavedSearch) {
        query = saved.query
        activeSaved = saved
        if selectedRootID != nil { selectedRootID = nil } else { refresh() }
    }

    /// Picks a folder in the sidebar. Leaving a saved search keeps its query in the box for the user to edit.
    func selectRoot(_ id: Int64?) {
        let wasSaved = activeSaved != nil
        activeSaved = nil
        if selectedRootID != id { selectedRootID = id } else if wasSaved { refresh() }
    }

    /// Searches for one tag, as the tag browser asks.
    func search(tag: TagName) {
        query = Self.searchText(for: tag)
        if selectedRootID != nil { selectedRootID = nil } else { refresh() }
    }

    static func searchText(for tag: TagName) -> String {
        func quoted(_ v: String) -> String {
            v.contains(where: { $0.isWhitespace || $0 == "(" || $0 == ")" || $0 == "\"" || $0 == ":" })
                ? "\"" + v.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" : v
        }
        return tag.display == tag.value ? quoted(tag.value) : "\(tag.namespace):\(quoted(tag.value))"
    }

    func reloadTags() {
        guard let library else { return }
        Task {
            let tags = await Task.detached { (try? library.allTags()) ?? [] }.value
            guard self.library === library else { return }
            allTags = tags
        }
    }

    // MARK: Tagging selected files

    /// Tags on the selected files, with how many of them carry each one.
    private func loadSelectionTags() {
        guard let library else { return }
        let selected = selectedFileIDs
        guard !selected.isEmpty else { selectionTags = []; selectionTagsListed = true; return }
        guard selected.count <= Self.tagListLimit else { selectionTags = []; selectionTagsListed = false; return }
        selectionTagsListed = true
        Task {
            let result = await Task.detached { () -> [SelectionTag] in
                var merged: [String: SelectionTag] = [:]
                for id in selected {
                    for info in (try? library.tags(forFile: id)) ?? [] {
                        let key = info.name.description
                        if var existing = merged[key] {
                            existing.count += 1
                            if existing.source != info.source { existing.source = "mixed" }
                            merged[key] = existing
                        } else {
                            merged[key] = SelectionTag(name: info.name, count: 1, source: info.source, status: info.status, confidence: info.confidence)
                        }
                    }
                }
                return merged.values.sorted { $0.name.description < $1.name.description }
            }.value
            guard self.library === library, selectedFileIDs == selected else { return }
            selectionTags = result
        }
    }

    nonisolated private static let tagListLimit = 2_000

    func addTag(_ text: String) {
        changeTags { library, id in _ = try library.addTag(text, toFile: id) }
    }

    func removeTag(_ name: TagName) {
        changeTags { library, id in _ = try library.removeTag(name.description, fromFile: id) }
    }

    private func changeTags(_ change: @escaping @Sendable (Library, Int64) throws -> Void) {
        guard let library, !selectedFileIDs.isEmpty, !tagBusy else { return }
        let ids = Array(selectedFileIDs)
        tagBusy = true
        Task {
            let error = await Task.detached { () -> String? in
                do { for id in ids { try change(library, id) }; return nil }
                catch { return error.localizedDescription }
            }.value
            tagBusy = false
            guard self.library === library else { return }
            errorMessage = error
            loadSelectionTags()
            reloadTags()
            refresh()
        }
    }

    // MARK: Background work

    private func reloadWaitingJobs() async {
        guard let library else { return }
        let counts = await Task.detached { (try? library.waitingJobCountsByKind()) ?? [:] }.value
        guard self.library === library else { return }
        var grouped: [JobGroup: Int] = [:]
        for (kind, n) in counts { grouped[JobGroup(kind), default: 0] += n }
        if grouped != waitingJobs { waitingJobs = grouped }
    }

    /// Stops the background queue between jobs. Queued work stays in the database; Resume picks it up.
    func pauseQueue() {
        jobQueue?.stop()
        queuePaused = true
    }

    func resumeQueue() {
        guard let queue = jobQueue else { return }
        queuePaused = false
        Task.detached { queue.start() }
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

    /// Where a file is on disk, for previewing. Nil when it cannot be found. Never downloads.
    func localURL(for file: IndexedFile) async -> URL? {
        guard let library else { return nil }
        let fs = fileSystem
        return await Task.detached { (try? library.absolutePath(of: file, fileSystem: fs)).map { URL(fileURLWithPath: $0) } }.value
    }

    /// Downloads one iCloud file because the user asked to preview it (ADR 0011), without opening it in another app.
    func download(_ file: IndexedFile) {
        guard let library else { return }
        status = "Downloading \((file.relativePath as NSString).lastPathComponent)…"
        let fs = fileSystem
        Task {
            let error = await Task.detached { () -> String? in
                do { _ = try ThumbnailService(library: library, fileSystem: fs).prepareToOpen(fileID: file.id); return nil }
                catch { return error.localizedDescription }
            }.value
            guard self.library === library else { return }
            status = nil
            errorMessage = error
            thumbnailGeneration += 1
            refresh()
        }
    }

    /// The selected files, in grid order.
    var selectedFiles: [IndexedFile] { files.filter { selectedFileIDs.contains($0.id) } }

    func openSelection() {
        for file in selectedFiles.prefix(10) { open(file) }
    }

    /// Shows the files in Finder. Revealing never downloads an iCloud file.
    func revealSelection() {
        guard let library else { return }
        let chosen = selectedFiles
        let fs = fileSystem
        Task {
            let urls = await Task.detached { chosen.compactMap { try? library.absolutePath(of: $0, fileSystem: fs) }.map { URL(fileURLWithPath: $0) } }.value
            guard self.library === library else { return }
            if urls.isEmpty { errorMessage = "Miles cannot find these files. Is their drive connected?" }
            else { NSWorkspace.shared.activateFileViewerSelecting(urls) }
        }
    }

    /// Quick Look on the selection. Files that are not downloaded are skipped: previewing must not download (ADR 0011).
    func quickLookSelection() {
        guard let library else { return }
        if quickLook.isShowing { quickLook.close(); return }
        let chosen = selectedFiles.prefix(200)
        let fs = fileSystem
        Task {
            let urls = await Task.detached { () -> [URL] in
                chosen.filter { $0.icloudStatus != "dataless" }
                    .compactMap { try? library.absolutePath(of: $0, fileSystem: fs) }
                    .map { URL(fileURLWithPath: $0) }
            }.value
            guard self.library === library else { return }
            if urls.isEmpty {
                if !chosen.isEmpty { errorMessage = "These files are not downloaded. Open one to download it, then preview it." }
            } else {
                quickLook.show(urls)
            }
        }
    }
}

/// A tag on the selected files and how many of them carry it.
struct SelectionTag: Identifiable, Equatable, Sendable {
    var name: TagName
    var count: Int
    var source: String
    var status: String
    var confidence: Double?
    var id: String { name.description }
}

/// What a waiting background job is for, as the status bar says it.
enum JobGroup: String, CaseIterable, Sendable {
    case tagging = "tagging", ai = "AI", duplicates = "duplicate checks", other = "other"

    init(_ kind: JobKind) {
        switch kind {
        case .tagMetadata, .tagPathRules: self = .tagging
        case .tagSystemML, .tagLLM: self = .ai
        case .fingerprint, .hashPartial, .hashFull: self = .duplicates
        default: self = .other
        }
    }
}
