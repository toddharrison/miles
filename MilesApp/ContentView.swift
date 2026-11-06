import MilesCore
import SwiftUI

struct ContentView: View {
    @Bindable var model: AppModel
    @State private var showingReview = false
    @State private var showingAsk = false
    @State private var showingInspector = true
    @State private var showingTags = false
    @State private var showingSaveSearch = false
    @State private var savedName = ""

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        } detail: {
            detail
        }
        .frame(minWidth: 760, minHeight: 480)
        .sheet(isPresented: $showingReview) { ReviewQueueView(model: model).toolbar { ToolbarItem { Button("Done") { showingReview = false } } } }
        .sheet(isPresented: $showingAsk) { AskView(model: model) }
        .alert("Something went wrong", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .confirmationDialog("Delete \(model.pendingLibraryDeletion?.name ?? "library")?",
                            isPresented: Binding(get: { model.pendingLibraryDeletion != nil }, set: { if !$0 { model.pendingLibraryDeletion = nil } }),
                            titleVisibility: .visible, presenting: model.pendingLibraryDeletion) { record in
            Button("Move Library Folder to Trash", role: .destructive) { model.deleteLibrary(record, moveFolderToTrash: true) }
            Button("Remove from List Only") { model.deleteLibrary(record, moveFolderToTrash: false) }
            Button("Cancel", role: .cancel) { model.pendingLibraryDeletion = nil }
        } message: { _ in
            Text("Your indexed files are never touched. The library folder holds Miles' index, tags, saved searches and backups. Moving it to the Trash loses them unless you put the folder back. Removing it from the list keeps the folder.")
        }
        .alert("Library is open elsewhere", isPresented: Binding(get: { model.pendingTakeOver != nil }, set: { if !$0 { model.pendingTakeOver = nil } })) {
            Button("Take Over", role: .destructive) { model.confirmTakeOver() }
            Button("Cancel", role: .cancel) { model.pendingTakeOver = nil }
        } message: {
            Text("Only take over if you are sure no other Mac or copy of Miles has this library open. Two openers at once can corrupt it. A crash on another Mac leaves this lock behind.")
        }
        .alert("Download files to build thumbnails?", isPresented: Binding(get: { model.pendingFetch != nil }, set: { if !$0 { model.pendingFetch = nil } })) {
            Button("Download") { model.approvePendingFetch() }
            Button("Not Now", role: .cancel) { model.pendingFetch = nil }
        } message: {
            if let plan = model.pendingFetch {
                Text("\(plan.fileCount) iCloud files (\(ByteCountFormatter.string(fromByteCount: plan.totalBytes, countStyle: .file))) would be downloaded once, then left for macOS to evict. This uses bandwidth and disk space.")
            }
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: sidebarSelection) {
            Section("Library") {
                libraryMenu
            }
            Section("Folders") {
                Label("All files", systemImage: "photo.on.rectangle")
                    .tag(SidebarItem.all)
                ForEach(model.roots) { root in
                    rootRow(root)
                }
            }
            if !model.savedSearches.isEmpty {
                Section("Saved Searches") {
                    ForEach(model.savedSearches, id: \.id) { saved in
                        Label(saved.name, systemImage: "magnifyingglass")
                            .tag(SidebarItem.saved(saved.id))
                            .help(saved.query)
                            .contextMenu { Button("Delete Saved Search", role: .destructive) { model.deleteSavedSearch(saved) } }
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem {
                Button("Add Folder", systemImage: "plus") { model.addRoot() }
                    .disabled(model.library == nil)
                    .help("Index a folder in place. Miles never moves or changes its files")
            }
        }
    }

    private func rootName(_ root: RootRecord) -> String {
        root.location.resolve(fileSystem: model.fileSystem).map { ($0 as NSString).lastPathComponent } ?? "Drive not mounted"
    }

    /// A root with its folder tree under it. Selecting the root shows just that root; each folder's checkbox
    /// shows or hides it in the grid and in search (view only, ADR 0017).
    @ViewBuilder private func rootRow(_ root: RootRecord) -> some View {
        let node = model.folderTree.first { $0.ref.rootID == root.id }
        let label = HStack(spacing: 6) {
            if let node { FolderCheckbox(model: model, node: node) }
            Label(rootName(root), systemImage: "folder")
        }
        .contextMenu { rootMenu(root) }
        if let node, !node.children.isEmpty {
            DisclosureGroup {
                ForEach(node.children) { FolderTreeRow(model: model, node: $0) }
            } label: { label.tag(SidebarItem.root(root.id)) }
        } else {
            label.tag(SidebarItem.root(root.id))
        }
    }

    @ViewBuilder private func rootMenu(_ root: RootRecord) -> some View {
        Toggle("Fetch iCloud files once for thumbnails", isOn: Binding(
            get: { root.fetchOnce }, set: { model.setFetchOnce($0, root: root.id) }))
        Toggle("Use the on-device language model on images and text (off by default)", isOn: Binding(
            get: { !root.layer4Kinds.isEmpty }, set: { model.setLayer4($0, root: root.id) }))
        Menu("Accept AI suggestions automatically") {
            Button("Never (review every suggestion)") { model.setAutoAccept(nil, root: root.id) }
            ForEach([0.95, 0.9, 0.8], id: \.self) { value in
                Button("At or above \(Int(value * 100))%") { model.setAutoAccept(value, root: root.id) }
            }
        }
        Divider()
        Button("Stop Indexing This Folder", role: .destructive) { model.removeRoot(root.id) }
    }

    private enum SidebarItem: Hashable { case all, root(Int64), saved(Int64) }

    private var sidebarSelection: Binding<SidebarItem?> {
        Binding {
            if let saved = model.activeSaved { return .saved(saved.id) }
            return model.selectedRootID.map { .root($0) } ?? .all
        } set: { item in
            switch item {
            case .saved(let id): if let saved = model.savedSearches.first(where: { $0.id == id }) { model.run(saved) }
            case .root(let id): model.selectRoot(id)
            case .all, nil: model.selectRoot(nil)
            }
        }
    }

    private var libraryMenu: some View {
        Menu {
            ForEach(model.libraries) { record in
                Button(record.name) { model.openLibrary(record.id) }
            }
            if !model.libraries.isEmpty { Divider() }
            Button("New Library…") { model.createLibrary() }
            if !model.libraries.isEmpty {
                Menu("Delete Library") {
                    ForEach(model.libraries) { record in
                        Button(record.name) { model.pendingLibraryDeletion = record }
                    }
                }
            }
        } label: {
            Label(model.libraryName ?? "Choose a library", systemImage: "books.vertical")
        }
        .menuStyle(.borderlessButton)
        .help("Switch library, create a new one, or delete one")
    }

    // MARK: Detail

    @ViewBuilder private var detail: some View {
        if model.library == nil, let unavailable = model.unavailable {
            ContentUnavailableView {
                Label("\(unavailable.libraryName) is unavailable", systemImage: unavailable.availability == .driveNotMounted ? "externaldrive.badge.xmark" : "exclamationmark.triangle")
            } description: {
                Text(unavailable.availability.message(libraryName: unavailable.libraryName))
            } actions: {
                if case .newerSchema = unavailable.availability {} else {
                    Button("Try Again") { model.retryWanted() }
                }
            }
        } else if model.library == nil {
            ContentUnavailableView {
                Label("No library open", systemImage: "books.vertical")
            } description: {
                Text("A library holds Miles' index and tags. Your files stay where they are.")
            } actions: {
                Button("New Library…") { model.createLibrary() }
            }
        } else if model.roots.isEmpty {
            ContentUnavailableView {
                Label("No folders yet", systemImage: "folder.badge.plus")
            } description: {
                Text("Add a folder to index it in place. Miles never moves or changes your files.")
            } actions: {
                Button("Add Folder…") { model.addRoot() }
            }
        } else {
            VStack(spacing: 0) {
                if let error = model.queryError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red).font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(.red.opacity(0.08))
                        .textSelection(.enabled)
                    Divider()
                }
                ThumbnailGrid(files: model.files, generation: model.thumbnailGeneration,
                              thumbnailPath: { model.thumbnailPath(for: $0) }, ensureThumbnail: { await model.ensureThumbnail($0) },
                              selection: model.selectedFileIDs, onSelect: { model.selectedFileIDs = $0 },
                              onOpen: { model.open($0) }, onOpenSelection: { model.openSelection() },
                              onReveal: { model.revealSelection() }, onQuickLook: { model.quickLookSelection() })
                Divider()
                statusBar
            }
            .searchable(text: $model.query, prompt: "Search: cat or dog, \"text\", type:image, size:>5mb")
            .searchSuggestions {
                ForEach(QueryCompletion.suggestions(for: model.query, tags: model.allTags), id: \.self) { completion in
                    Text(completion).searchCompletion(completion)
                }
                ForEach(model.searchHistory.filter { model.query.isEmpty || ($0.localizedCaseInsensitiveContains(model.query) && $0 != model.query) }, id: \.self) { past in
                    Label(past, systemImage: "clock").searchCompletion(past)
                }
            }
            .onSubmit(of: .search) { model.refresh() }
            .inspector(isPresented: $showingInspector) { InspectorView(model: model) }
            .alert("Save Search", isPresented: $showingSaveSearch) {
                TextField("Name", text: $savedName)
                Button("Save") { model.saveCurrentSearch(named: savedName) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Saves \"\(model.query)\". It runs again with whatever matches then, including later tag changes.")
            }
            .toolbar {
                ToolbarItemGroup {
                    Button("Open", systemImage: "arrow.up.forward.app") { model.openSelection() }
                        .keyboardShortcut("o").disabled(model.selectedFileIDs.isEmpty)
                        .help("Open the selected files (⌘O). An iCloud file is downloaded first")
                    Button("Reveal in Finder", systemImage: "folder") { model.revealSelection() }
                        .keyboardShortcut("r", modifiers: [.command, .shift]).disabled(model.selectedFileIDs.isEmpty)
                        .help("Show the selected files in Finder (⇧⌘R)")
                    Button("Quick Look", systemImage: "eye") { model.quickLookSelection() }
                        .keyboardShortcut("y").disabled(model.selectedFileIDs.isEmpty)
                        .help("Preview the selected files (Space or ⌘Y). Files not downloaded from iCloud are skipped")
                }
                ToolbarItem {
                    Button("Save Search", systemImage: "bookmark") { savedName = ""; showingSaveSearch = true }
                        .disabled(model.query.trimmingCharacters(in: .whitespaces).isEmpty || model.queryError != nil)
                        .help("Save the current search under a name, in the sidebar")
                }
                ToolbarItem {
                    Button("Browse Tags", systemImage: "tag") { showingTags = true }
                        .help("List every tag with its file count; click one to search for it")
                        .popover(isPresented: $showingTags) { TagBrowserView(model: model, isPresented: $showingTags) }
                }
                ToolbarItem {
                    Button("Inspector", systemImage: "sidebar.trailing") { showingInspector.toggle() }
                        .help("Show or hide the tag inspector")
                }
                ToolbarItem {
                    Button("Ask in Plain Language", systemImage: "sparkles") { showingAsk = true }
                        .help("Describe what you want in words; the on-device model writes the search for you to check")
                }
                ToolbarItem {
                    Button("Review \(model.suggestionCount) Suggestions", systemImage: "checklist") { showingReview = true }
                        .badge(model.suggestionCount)
                        .disabled(model.suggestionCount == 0)
                        .help("Accept or reject tags the on-device AI suggested")
                }
                ToolbarItem {
                    Button("Scan Folders", systemImage: "arrow.clockwise") { model.scan() }
                        .disabled(model.status != nil)
                        .help("Look for new, changed and missing files in every folder, then build thumbnails")
                }
            }
        }
    }

    private var statusBar: some View {
        HStack {
            if model.status != nil {
                if let fraction = model.progress {
                    ProgressView(value: fraction).frame(width: 140)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            Text(model.status ?? summary).foregroundStyle(.secondary).font(.callout)
            if model.folderFilter.isActive {
                let folders = model.folderSummary
                Button("\(folders.shown) of \(folders.total) folders · Show All") { model.showAllFolders() }
                    .buttonStyle(.link).font(.callout)
                    .help("Some folders are unchecked in the sidebar and hidden from the grid and search. Click to show them all")
            }
            Spacer()
            if model.selectedFileIDs.count > 1 {
                Text("\(model.selectedFileIDs.count.formatted()) selected").foregroundStyle(.secondary).font(.callout)
            }
            queueStatus
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    /// Background tagging, AI and duplicate hashing, with pause and resume. A scan runs to completion once started.
    @ViewBuilder private var queueStatus: some View {
        let total = model.waitingJobs.values.reduce(0, +)
        if total > 0 || model.queuePaused {
            let parts = JobGroup.allCases.compactMap { group in
                model.waitingJobs[group].map { "\($0.formatted()) \(group.rawValue)" }
            }
            Text((model.queuePaused ? "Paused: " : "Working: ") + (parts.isEmpty ? "nothing waiting" : parts.joined(separator: ", ")))
                .foregroundStyle(.secondary).font(.callout)
            if !model.queuePaused, let fraction = model.queueProgress {
                ProgressView(value: fraction).frame(width: 100)
                    .help("\(Int(fraction * 100))% of the current batch of background work")
            } else if !model.queuePaused && total > 0 {
                ProgressView().controlSize(.small)
            }
            Button(model.queuePaused ? "Resume" : "Pause", systemImage: model.queuePaused ? "play.fill" : "pause.fill") {
                if model.queuePaused { model.resumeQueue() } else { model.pauseQueue() }
            }
            .labelStyle(.iconOnly).buttonStyle(.borderless)
            .help(model.queuePaused ? "Resume background work" : "Pause background work")
        }
    }

    private var summary: String {
        let shown = model.files.count
        return shown == model.totalFiles ? "\(shown) files" : "\(shown) of \(model.totalFiles) files"
    }
}

/// A folder checkbox: all, none or mixed (some folders below are unchecked).
private struct FolderCheckbox: View {
    let model: AppModel
    let node: FolderNode

    var body: some View {
        let state = model.folderFilter.state(of: node)
        Button {
            model.toggleFolder(node)
        } label: {
            Image(systemName: state == .on ? "checkmark.square.fill" : state == .mixed ? "minus.square.fill" : "square")
                .foregroundStyle(state == .off ? Color.secondary : Color.accentColor)
        }
        .buttonStyle(.plain)
        .help(state == .on ? "Hide this folder and the ones below it from the grid and search" : "Show this folder and the ones below it")
    }
}

/// A folder below a root: checkbox, name and file count, with its own subfolders under a disclosure triangle.
private struct FolderTreeRow: View {
    let model: AppModel
    let node: FolderNode

    var body: some View {
        if node.children.isEmpty {
            row
        } else {
            DisclosureGroup { ForEach(node.children) { FolderTreeRow(model: model, node: $0) } } label: { row }
        }
    }

    private var row: some View {
        HStack(spacing: 6) {
            FolderCheckbox(model: model, node: node)
            Label(node.name, systemImage: "folder")
            Spacer(minLength: 4)
            if node.fileCount > 0 { Text(node.fileCount.formatted()).font(.caption).foregroundStyle(.tertiary) }
        }
    }
}
