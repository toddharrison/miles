import AppKit
import MilesCore
import SwiftUI

/// The thumbnail grid. AppKit-backed (NSCollectionView) because it must stay smooth with very large
/// result sets (ADR 0013). Items are created lazily; thumbnails load from the library's cache on
/// demand, and a file without one shows a kind icon, with a cloud badge when it is not on disk.
struct ThumbnailGrid: NSViewRepresentable {
    var files: [IndexedFile]
    var generation: Int
    var thumbnailPath: (Int64) -> String
    /// Makes a missing thumbnail when its cell appears. True if one exists afterwards.
    var ensureThumbnail: (Int64) async -> Bool
    /// File ids selected in the grid. The grid reports the user's changes and shows what the model holds.
    var selection: Set<Int64>
    var onSelect: (Set<Int64>) -> Void
    var onOpen: (IndexedFile) -> Void
    var onOpenSelection: () -> Void
    var onReveal: () -> Void
    var onQuickLook: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 150, height: 176)
        layout.minimumInteritemSpacing = 10
        layout.minimumLineSpacing = 10
        layout.sectionInset = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)

        let collection = OpenableCollectionView()
        collection.collectionViewLayout = layout
        collection.isSelectable = true
        collection.allowsMultipleSelection = true
        collection.backgroundColors = [.clear]
        collection.dataSource = context.coordinator
        collection.delegate = context.coordinator
        collection.register(GridItem.self, forItemWithIdentifier: GridItem.identifier)
        let coordinator = context.coordinator
        collection.onOpen = { [weak coordinator] index in coordinator?.open(index) }
        collection.onSelectionChanged = { [weak coordinator] in coordinator?.reportSelection() }
        collection.onOpenSelection = { [weak coordinator] in coordinator?.onOpenSelection() }
        collection.onQuickLook = { [weak coordinator] in coordinator?.onQuickLook() }
        let menu = NSMenu()
        for (title, action) in [("Open", #selector(Coordinator.menuOpen)), ("Reveal in Finder", #selector(Coordinator.menuReveal)),
                                ("Quick Look", #selector(Coordinator.menuQuickLook))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = coordinator
            menu.addItem(item)
        }
        collection.menu = menu
        coordinator.collection = collection

        let scroll = NSScrollView()
        scroll.documentView = collection
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        c.thumbnailPath = thumbnailPath
        c.ensureThumbnail = ensureThumbnail
        c.onOpen = onOpen
        c.onSelect = onSelect
        c.onOpenSelection = onOpenSelection
        c.onReveal = onReveal
        c.onQuickLook = onQuickLook
        let changed = c.files != files
        let regenerated = c.generation != generation
        c.files = files
        if regenerated { c.generation = generation; c.images.removeAllObjects() }
        if changed || regenerated { c.collection?.reloadData() }
        // reloadData drops the selection, so put the model's back whenever the items or the selection changed.
        if changed || regenerated || c.selection != selection {
            c.selection = selection
            c.collection?.selectionIndexPaths = Set(files.indices.filter { selection.contains(files[$0].id) }.map { IndexPath(item: $0, section: 0) })
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate {
        var files: [IndexedFile] = []
        var selection: Set<Int64> = []
        var onSelect: (Set<Int64>) -> Void = { _ in }
        var onOpenSelection: () -> Void = {}
        var onReveal: () -> Void = {}
        var onQuickLook: () -> Void = {}
        var generation = 0
        var thumbnailPath: (Int64) -> String = { _ in "" }
        var ensureThumbnail: (Int64) async -> Bool = { _ in false }
        var onOpen: (IndexedFile) -> Void = { _ in }
        weak var collection: NSCollectionView?
        let images = NSCache<NSNumber, NSImage>()

        func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { files.count }

        func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
            let item = collectionView.makeItem(withIdentifier: GridItem.identifier, for: indexPath)
            guard let cell = item as? GridItem, indexPath.item < files.count else { return item }
            cell.configure(files[indexPath.item], path: thumbnailPath(files[indexPath.item].id), cache: images, ensure: ensureThumbnail)
            return cell
        }

        func open(_ index: Int) {
            guard index < files.count else { return }
            onOpen(files[index])
        }

        func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) { reportSelection() }
        func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) { reportSelection() }

        func reportSelection() {
            guard let collection else { return }
            let ids = Set(collection.selectionIndexPaths.compactMap { $0.item < files.count ? files[$0.item].id : nil })
            selection = ids
            onSelect(ids)
        }

        @objc func menuOpen() { onOpenSelection() }
        @objc func menuReveal() { onReveal() }
        @objc func menuQuickLook() { onQuickLook() }
    }
}

/// Adds what NSCollectionView lacks: double-click to open, Return to open, Space for Quick Look, and a context
/// menu that acts on the item under the pointer. Arrow keys and Command-A come from NSCollectionView itself.
final class OpenableCollectionView: NSCollectionView {
    var onOpen: ((Int) -> Void)?
    var onSelectionChanged: (() -> Void)?
    var onOpenSelection: (() -> Void)?
    var onQuickLook: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 49: onQuickLook?()
        case 36, 76: onOpenSelection?()
        default: super.keyDown(with: event)
        }
    }

    override func selectAll(_ sender: Any?) {
        super.selectAll(sender)
        onSelectionChanged?()
    }

    override func deselectAll(_ sender: Any?) {
        super.deselectAll(sender)
        onSelectionChanged?()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let path = indexPathForItem(at: convert(event.locationInWindow, from: nil)) else { return nil }
        if !selectionIndexPaths.contains(path) {
            selectionIndexPaths = [path]
            onSelectionChanged?()
        }
        return super.menu(for: event)
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        guard event.clickCount == 2, let path = indexPathForItem(at: convert(event.locationInWindow, from: nil)) else { return }
        onOpen?(path.item)
    }
}

final class GridItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("GridItem")

    private let picture = NSImageView()
    private let badge = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var fileID: Int64 = -1

    override func loadView() {
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 150, height: 176))
        box.wantsLayer = true
        box.layer?.cornerRadius = 8

        picture.imageScaling = .scaleProportionallyUpOrDown
        picture.translatesAutoresizingMaskIntoConstraints = false
        badge.image = NSImage(systemSymbolName: "icloud.fill", accessibilityDescription: "Not downloaded")
        badge.contentTintColor = .systemBlue
        badge.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingMiddle
        label.alignment = .center
        label.font = .systemFont(ofSize: 11)
        label.translatesAutoresizingMaskIntoConstraints = false
        for view in [picture, badge, label] { box.addSubview(view) }

        NSLayoutConstraint.activate([
            picture.topAnchor.constraint(equalTo: box.topAnchor, constant: 6),
            picture.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 6),
            picture.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -6),
            picture.heightAnchor.constraint(equalToConstant: 138),
            badge.trailingAnchor.constraint(equalTo: picture.trailingAnchor),
            badge.bottomAnchor.constraint(equalTo: picture.bottomAnchor),
            badge.widthAnchor.constraint(equalToConstant: 20),
            badge.heightAnchor.constraint(equalToConstant: 20),
            label.topAnchor.constraint(equalTo: picture.bottomAnchor, constant: 4),
            label.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -6),
        ])
        view = box
    }

    override var isSelected: Bool {
        didSet { view.layer?.backgroundColor = isSelected ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.35).cgColor : nil }
    }

    func configure(_ file: IndexedFile, path: String, cache: NSCache<NSNumber, NSImage>, ensure: @escaping (Int64) async -> Bool) {
        fileID = file.id
        label.stringValue = (file.relativePath as NSString).lastPathComponent
        let notOnDisk = file.icloudStatus == "dataless"
        badge.isHidden = !notOnDisk
        // Placeholder first, so scrolling never waits on the disk.
        showPlaceholder(kind: file.kind, dimmed: notOnDisk)
        if let cached = cache.object(forKey: NSNumber(value: file.id)) {
            show(cached)
            return
        }
        let id = file.id
        let canRender = !notOnDisk && file.kind == "image"
        Task { [weak self] in
            func read() async -> Data? { await Task.detached(priority: .utility) { try? Data(contentsOf: URL(fileURLWithPath: path)) }.value }
            var data = await read()
            // No cached thumbnail yet: make it now, for this cell, instead of waiting for a pass over everything.
            if data == nil, canRender, await ensure(id) { data = await read() }
            guard let data, let image = NSImage(data: data), let self, self.fileID == id else { return }
            cache.setObject(image, forKey: NSNumber(value: id))
            self.show(image)
        }
    }

    private func show(_ image: NSImage) {
        picture.image = image
        picture.contentTintColor = nil
        picture.alphaValue = 1
    }

    private func showPlaceholder(kind: String?, dimmed: Bool) {
        let symbol = switch kind {
        case "image": "photo"
        case "video": "film"
        case "audio": "waveform"
        case "document": "doc.richtext"
        case "text": "doc.text"
        case "archive": "archivebox"
        default: "doc"
        }
        picture.image = NSImage(systemSymbolName: symbol, accessibilityDescription: kind)?
            .withSymbolConfiguration(.init(pointSize: 44, weight: .light))
        picture.contentTintColor = .secondaryLabelColor
        picture.alphaValue = dimmed ? 0.5 : 0.8
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        fileID = -1
    }
}
