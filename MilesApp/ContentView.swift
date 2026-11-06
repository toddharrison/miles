import MilesCore
import SwiftUI

struct ContentView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        } detail: {
            detail
        }
        .frame(minWidth: 760, minHeight: 480)
        .alert("Something went wrong", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
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
        List(selection: $model.selectedRootID) {
            Section("Library") {
                libraryMenu
            }
            Section("Folders") {
                Label("All files", systemImage: "photo.on.rectangle")
                    .tag(Int64?.none)
                ForEach(model.roots) { root in
                    Label(root.location.resolve(fileSystem: model.fileSystem).map { ($0 as NSString).lastPathComponent } ?? "Drive not mounted",
                          systemImage: "folder")
                        .tag(Int64?.some(root.id))
                        .contextMenu {
                            Toggle("Fetch iCloud files once for thumbnails", isOn: Binding(
                                get: { root.fetchOnce }, set: { model.setFetchOnce($0, root: root.id) }))
                            Divider()
                            Button("Stop Indexing This Folder", role: .destructive) { model.removeRoot(root.id) }
                        }
                }
            }
        }
        .toolbar {
            ToolbarItem {
                Button("Add Folder", systemImage: "plus") { model.addRoot() }
                    .disabled(model.library == nil)
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
        } label: {
            Label(model.libraryName ?? "Choose a library", systemImage: "books.vertical")
        }
        .menuStyle(.borderlessButton)
    }

    // MARK: Detail

    @ViewBuilder private var detail: some View {
        if model.library == nil {
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
                ThumbnailGrid(files: model.files, generation: model.thumbnailGeneration,
                              thumbnailPath: { model.thumbnailPath(for: $0) }, onOpen: { model.open($0) })
                Divider()
                HStack {
                    Text(model.status ?? summary).foregroundStyle(.secondary).font(.callout)
                    Spacer()
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
            }
            .searchable(text: $model.query, prompt: "Search: cat or dog, \"text\", type:image, size:>5mb")
            .onSubmit(of: .search) { model.refresh() }
            .toolbar {
                ToolbarItem {
                    Button("Scan Folders", systemImage: "arrow.clockwise") { model.scan() }
                }
            }
        }
    }

    private var summary: String {
        let shown = model.files.count
        return shown == model.totalFiles ? "\(shown) files" : "\(shown) of \(model.totalFiles) files"
    }
}
