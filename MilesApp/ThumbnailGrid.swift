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
    var onOpen: (IndexedFile) -> Void

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
        collection.register(GridItem.self, forItemWithIdentifier: GridItem.identifier)
        collection.onOpen = { [weak coordinator = context.coordinator] index in coordinator?.open(index) }
        context.coordinator.collection = collection

        let scroll = NSScrollView()
        scroll.documentView = collection
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        c.thumbnailPath = thumbnailPath
        c.onOpen = onOpen
        let changed = c.files != files
        let regenerated = c.generation != generation
        c.files = files
        if regenerated { c.generation = generation; c.images.removeAllObjects() }
        if changed || regenerated { c.collection?.reloadData() }
    }

    @MainActor
    final class Coordinator: NSObject, NSCollectionViewDataSource {
        var files: [IndexedFile] = []
        var generation = 0
        var thumbnailPath: (Int64) -> String = { _ in "" }
        var onOpen: (IndexedFile) -> Void = { _ in }
        weak var collection: NSCollectionView?
        let images = NSCache<NSNumber, NSImage>()

        func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { files.count }

        func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
            let item = collectionView.makeItem(withIdentifier: GridItem.identifier, for: indexPath)
            guard let cell = item as? GridItem, indexPath.item < files.count else { return item }
            cell.configure(files[indexPath.item], path: thumbnailPath(files[indexPath.item].id), cache: images)
            return cell
        }

        func open(_ index: Int) {
            guard index < files.count else { return }
            onOpen(files[index])
        }
    }
}

/// Reports a double-click on an item. NSCollectionView has no built-in action for it.
final class OpenableCollectionView: NSCollectionView {
    var onOpen: ((Int) -> Void)?

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

    func configure(_ file: IndexedFile, path: String, cache: NSCache<NSNumber, NSImage>) {
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
        Task { [weak self] in
            let data = await Task.detached(priority: .utility) { try? Data(contentsOf: URL(fileURLWithPath: path)) }.value
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
