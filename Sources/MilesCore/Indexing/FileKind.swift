import Foundation
import UniformTypeIdentifiers

/// Coarse file kind recorded on `file.kind`, from the extension. Content is never read to decide it.
public enum FileKind: String, Sendable, CaseIterable {
    case image, video, audio, document, text, archive, other

    /// Caches extension lookups: a type lookup per file would dominate a large scan.
    final class Classifier: @unchecked Sendable {
        private var cache: [String: FileKind] = [:]
        private let lock = NSLock()

        func kind(forFileName name: String) -> FileKind {
            let ext = (name as NSString).pathExtension.lowercased()
            if ext.isEmpty { return .other }
            return lock.withLock {
                if let hit = cache[ext] { return hit }
                let kind = FileKind.compute(ext)
                cache[ext] = kind
                return kind
            }
        }
    }

    private static func compute(_ ext: String) -> FileKind {
        guard let type = UTType(filenameExtension: ext) else { return .other }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .archive) { return .archive }
        if type.conforms(to: .pdf) || type.conforms(to: .presentation) || type.conforms(to: .spreadsheet)
            || type.conforms(to: .rtf) || type.conforms(to: .flatRTFD) { return .document }
        if type.conforms(to: .text) { return .text }
        return .other
    }
}
