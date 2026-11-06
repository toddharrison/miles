import Foundation
import CryptoKit

/// SHA-256 of file content, read in chunks so large files never sit in memory.
/// Re-matches a moved file by content (Step 1) and decides exact duplicates (Step 6, ADR 0007).
enum ContentHash {
    static let chunkSize = 1 << 20

    /// Full-content hash, or nil if the file cannot be read. Callers must not call this for dataless files.
    static func full(of path: String, fileSystem fs: FileSystem) -> Data? {
        var hasher = SHA256()
        var offset: Int64 = 0
        do {
            while true {
                let chunk = try fs.readRange(at: path, offset: offset, length: chunkSize)
                if chunk.isEmpty { break }
                hasher.update(data: chunk)
                offset += Int64(chunk.count)
            }
        } catch { return nil }
        return Data(hasher.finalize())
    }

    /// Bytes read at each of the start, middle and end for the partial hash.
    static let partialSpan = 64 * 1024

    /// Cheap fingerprint for ruling out files that share a size but not content: SHA-256 of the size and
    /// the start, middle and end of the file. Equal partial hashes never prove equality; only the full hash does.
    static func partial(of path: String, size: Int64, fileSystem fs: FileSystem) -> Data? {
        var hasher = SHA256()
        withUnsafeBytes(of: size.littleEndian) { hasher.update(bufferPointer: $0) }
        let span = Int64(partialSpan)
        let offsets = [0, max(0, size / 2 - span / 2), max(0, size - span)]
        do {
            for offset in offsets { hasher.update(data: try fs.readRange(at: path, offset: offset, length: partialSpan)) }
        } catch { return nil }
        return Data(hasher.finalize())
    }
}
