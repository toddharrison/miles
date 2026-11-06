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
    /// An image with several frames (GIF, APNG, animated WebP), played by AppKit instead of shown as one frame.
    @State private var animated: NSImage?
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
            PlayerView(player: player)
        } else if let animated {
            AnimatedImageView(image: animated)
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
        animated = nil
        failed = false
        guard file.icloudStatus != "dataless", let kind = file.kind, ["image", "video", "audio"].contains(kind) else { return }
        guard let url = await model.localURL(for: file) else { failed = true; return }
        if kind == "image" {
            // A still image is decoded at screen size, so a 100-megapixel photo does not fill memory.
            // A multi-frame image is loaded whole so it can play; the size cap keeps a huge one from filling memory.
            let decoded = await Task.detached { () -> (still: CGImage?, frames: NSImage?) in
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return (nil, nil) }
                let type = CGImageSourceGetType(source) as String?
                let playable = ["com.compuserve.gif", "public.png", "org.webmproject.webp"].contains(type ?? "")
                if playable, CGImageSourceGetCount(source) > 1,
                   let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 64_000_000,
                   let frames = NSImage(contentsOf: url) {
                    return (nil, frames)
                }
                return (CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 1600,
                ] as CFDictionary), nil)
            }.value
            guard !Task.isCancelled else { return }
            if let frames = decoded.frames { animated = frames }
            else if let still = decoded.still { image = NSImage(cgImage: still, size: .zero) }
            else { failed = true }
        } else {
            guard !Task.isCancelled else { return }
            player = AVPlayer(url: url)
        }
    }
}

/// AppKit's player with its standard controls. SwiftUI's `VideoPlayer` aborted at runtime when first shown in this
/// app (Swift metadata failure inside the SwiftUI/AVKit overlay), so the AppKit view is wrapped directly.
struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = true
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player?.pause()
        view.player = nil
    }
}

/// Plays a multi-frame image. NSImageView animates GIFs itself once `animates` is on.
struct AnimatedImageView: NSViewRepresentable {
    let image: NSImage

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.animates = true
        // Let the image shrink to the panel instead of forcing the panel to the image's size.
        view.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        view.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .vertical)
        view.image = image
        return view
    }

    func updateNSView(_ view: NSImageView, context: Context) {
        if view.image !== image { view.image = image }
    }
}
