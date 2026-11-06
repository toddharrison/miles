import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The cached sizes (longest edge in pixels). Each is a separate file under `thumbnails/<pixels>/` (ADR 0011).
public enum ThumbnailSize: Int, CaseIterable, Sendable {
    case small = 128, medium = 256
}

public enum ThumbnailRenderError: Error, Equatable, Sendable {
    case unreadable(String)
    case encodingFailed
}

/// Turns a local file into JPEG thumbnail bytes. MilesCore cannot use AppKit, so richer renderers
/// (Quick Look for video and PDF, say) can be supplied by the app through this protocol.
/// A renderer reads the file's content, so it must only ever be given a file that is on disk.
public protocol ThumbnailRenderer: Sendable {
    func canRender(kind: String?) -> Bool
    func render(path: String, maxPixelSize: Int) throws -> Data
}

/// Images through ImageIO (JPEG, PNG, HEIC, RAW and so on).
public struct ImageIORenderer: ThumbnailRenderer {
    public init() {}

    public func canRender(kind: String?) -> Bool { kind == FileKind.image.rawValue }

    public func render(path: String, maxPixelSize: Int) throws -> Data {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else {
            throw ThumbnailRenderError.unreadable(path)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ThumbnailRenderError.unreadable(path)
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ThumbnailRenderError.encodingFailed
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ThumbnailRenderError.encodingFailed }
        return data as Data
    }
}
