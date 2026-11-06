import AppKit
@preconcurrency import Quartz

/// Quick Look for the grid's selection. Only files that are already on disk are handed to it (ADR 0011).
@MainActor
final class QuickLook: NSObject, QLPreviewPanelDataSource {
    private var urls: [URL] = []

    var isShowing: Bool { QLPreviewPanel.sharedPreviewPanelExists() && (QLPreviewPanel.shared()?.isVisible ?? false) && QLPreviewPanel.shared()?.dataSource === self }

    func show(_ urls: [URL]) {
        self.urls = urls
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        guard isShowing else { return }
        QLPreviewPanel.shared()?.orderOut(nil)
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { urls.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated { urls.indices.contains(index) ? urls[index] as NSURL : nil }
    }
}
