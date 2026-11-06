import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ImageFormat: String, Sendable { case jpeg, heic }

/// What standardization needs to know about an image before it decides anything.
public struct ImageInfo: Equatable, Sendable {
    /// Nil for a format Miles does not re-encode (PNG, RAW, TIFF, ...).
    public var format: ImageFormat?
    public var width: Int
    public var height: Int
    /// More than one frame: animated or a multi-image container. Never re-encoded.
    public var frameCount: Int
    public var isRaw: Bool
    public var hasLocation: Bool
    public var longEdge: Int { max(width, height) }

    public init(format: ImageFormat?, width: Int, height: Int, frameCount: Int = 1, isRaw: Bool = false, hasLocation: Bool = false) {
        self.format = format; self.width = width; self.height = height
        self.frameCount = frameCount; self.isRaw = isRaw; self.hasLocation = hasLocation
    }
}

/// Reads and re-encodes image bytes. MilesCore may use ImageIO but not AppKit, and tests need a
/// deterministic stand-in, so the work sits behind this protocol.
public protocol ImageTranscoder: Sendable {
    func inspect(_ data: Data) -> ImageInfo?
    /// Re-encodes in the same format. Scales down so the long edge is at most `maxLongEdge` (never up),
    /// keeps orientation, EXIF and the colour profile, and drops GPS data only if `stripLocation`.
    func encode(_ data: Data, maxLongEdge: Int?, quality: Double, stripLocation: Bool) throws -> Data
}

public enum TranscodeError: Error, Equatable, LocalizedError, Sendable {
    case unreadable, unsupported, encodingFailed
    public var errorDescription: String? {
        switch self {
        case .unreadable: "the image could not be read"
        case .unsupported: "this image format is not re-encoded"
        case .encodingFailed: "the image could not be re-encoded"
        }
    }
}

/// ImageIO implementation. JPEG and HEIC are re-encoded; everything else is reported as unsupported.
public struct ImageIOTranscoder: ImageTranscoder {
    public init() {}

    public func inspect(_ data: Data) -> ImageInfo? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        guard let width = props[kCGImagePropertyPixelWidth] as? Int, let height = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        let type = CGImageSourceGetType(source).map { UTType($0 as String) } ?? nil
        let format: ImageFormat? = type == .jpeg ? .jpeg : type == .heic ? .heic : nil
        return ImageInfo(format: format, width: width, height: height, frameCount: CGImageSourceGetCount(source),
                         isRaw: type?.conforms(to: UTType("public.camera-raw-image") ?? .rawImage) ?? false,
                         hasLocation: props[kCGImagePropertyGPSDictionary] != nil)
    }

    public func encode(_ data: Data, maxLongEdge: Int?, quality: Double, stripLocation: Bool) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) == 1,
              let info = inspect(data) else { throw TranscodeError.unreadable }
        guard let format = info.format else { throw TranscodeError.unsupported }
        let type: UTType = format == .jpeg ? .jpeg : .heic
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil) else { throw TranscodeError.encodingFailed }
        var options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        if let maxLongEdge, info.longEdge > maxLongEdge { options[kCGImageDestinationImageMaxPixelSize] = maxLongEdge }
        if stripLocation { options[kCGImageMetadataShouldExcludeGPS] = true }
        // From the source, so orientation, EXIF and the colour profile travel with the pixels.
        CGImageDestinationAddImageFromSource(destination, source, 0, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw TranscodeError.encodingFailed }
        return out as Data
    }
}
