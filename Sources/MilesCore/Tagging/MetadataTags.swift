import AVFoundation
import Foundation
import ImageIO

/// What a probe could read from a file's content.
public struct MediaInfo: Equatable, Sendable {
    public var width: Int?
    public var height: Int?
    /// Seconds.
    public var duration: TimeInterval?
    public init(width: Int? = nil, height: Int? = nil, duration: TimeInterval? = nil) {
        self.width = width
        self.height = height
        self.duration = duration
    }
}

/// Reads dimensions and duration. It reads content, so it is only ever given a file that is on disk.
public protocol MetadataProbe: Sendable {
    func probe(path: String, kind: FileKind) async throws -> MediaInfo
}

/// ImageIO for image dimensions (header only, no decoding) and AVFoundation for video and audio.
public struct SystemMetadataProbe: MetadataProbe {
    public init() {}

    public func probe(path: String, kind: FileKind) async throws -> MediaInfo {
        let url = URL(fileURLWithPath: path)
        switch kind {
        case .image:
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
                throw ThumbnailRenderError.unreadable(path)
            }
            return MediaInfo(width: (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
                             height: (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue)
        case .video, .audio:
            let asset = AVURLAsset(url: url)
            let seconds = CMTimeGetSeconds(try await asset.load(.duration))
            var info = MediaInfo(duration: seconds.isFinite && seconds >= 0 ? seconds : nil)
            if kind == .video, let track = try await asset.loadTracks(withMediaType: .video).first {
                let size = try await track.load(.naturalSize)
                info.width = Int(size.width.rounded())
                info.height = Int(size.height.rounded())
            }
            return info
        default:
            return MediaInfo()
        }
    }
}

/// Layer 1: tags derived from file metadata (ADR 0010, 0014). Deterministic, so they are applied directly.
public enum MetadataTagger {
    /// Bump when the rules below change, so layer 1 re-runs for every file.
    static let version = 1

    /// `kind:` and `year:` come from the index. `resolution:` and `length:` need `info` from the content.
    public static func tags(kind: String?, modified: Date, info: MediaInfo?, calendar: Calendar = .current) -> [TagName] {
        var tags: [TagName] = []
        func add(_ namespace: String, _ value: String) {
            if let tag = try? TagName(namespace: namespace, value: value) { tags.append(tag) }
        }
        if let kind, kind != FileKind.other.rawValue { add("kind", kind) }
        add("year", String(calendar.component(.year, from: modified)))
        if let info {
            if let w = info.width, let h = info.height, w > 0, h > 0 { add("resolution", resolution(longestEdge: max(w, h))) }
            if let seconds = info.duration { add("length", length(seconds: seconds)) }
        }
        return tags
    }

    static func resolution(longestEdge: Int) -> String {
        switch longestEdge {
        case 3840...: "uhd"
        case 1920...: "fhd"
        case 1280...: "hd"
        default: "sd"
        }
    }

    static func length(seconds: TimeInterval) -> String {
        switch seconds {
        case ..<60: "short"
        case ..<600: "medium"
        case ..<3600: "long"
        default: "feature"
        }
    }
}
