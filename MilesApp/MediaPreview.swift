import AVKit
import ImageIO
import MilesCore
import SwiftUI

/// Shows one file in the inspector: images inline, video and audio with playback controls. A file that is not
/// downloaded from iCloud is not read; the user can choose to download it (ADR 0011).
struct MediaPreview: View {
    @Bindable var model: AppModel
    let file: IndexedFile
    @State private var image: NSImage?
    @State private var player: AVPlayer?
    @State private var failed = false

    var body: some View {
        content
            .frame(maxWidth: .infinity, minHeight: 120, maxHeight: 300)
            .task(id: "\(file.id)-\(file.icloudStatus)-\(file.modified)") { await load() }
            .onDisappear { player?.pause() }
    }

    @ViewBuilder private var content: some View {
        if file.icloudStatus == "dataless" {
            VStack(spacing: 8) {
                if let thumb = NSImage(contentsOfFile: model.thumbnailPath(for: file.id)) {
                    Image(nsImage: thumb).resizable().scaledToFit().opacity(0.6)
                }
                Label("In iCloud, not downloaded", systemImage: "icloud").foregroundStyle(.secondary)
                Button("Download to Preview") { model.download(file) }
                    .help("Downloads this one file from iCloud so it can be previewed")
            }
        } else if let player {
            VideoPlayer(player: player)
        } else if let image {
            Image(nsImage: image).resizable().scaledToFit()
        } else if failed {
            Label("No preview for this file", systemImage: "eye.slash").foregroundStyle(.secondary)
        } else if file.kind == "image" || file.kind == "video" || file.kind == "audio" {
            ProgressView().controlSize(.small)
        } else {
            Label("No preview for this kind of file", systemImage: "doc").foregroundStyle(.secondary)
        }
    }

    private func load() async {
        player?.pause()
        player = nil
        image = nil
        failed = false
        guard file.icloudStatus != "dataless", let kind = file.kind, ["image", "video", "audio"].contains(kind) else { return }
        guard let url = await model.localURL(for: file) else { failed = true; return }
        if kind == "image" {
            // Decode at screen size, so a 100-megapixel photo does not fill memory.
            let decoded = await Task.detached { () -> CGImage? in
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
                return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 1600,
                ] as CFDictionary)
            }.value
            guard !Task.isCancelled else { return }
            if let decoded { image = NSImage(cgImage: decoded, size: .zero) } else { failed = true }
        } else {
            guard !Task.isCancelled else { return }
            player = AVPlayer(url: url)
        }
    }
}
