import Foundation
import CryptoKit

/// SHA-256 of file content, read in chunks so large files never sit in memory.
/// Step 1 uses it only to re-match a moved file by content. Step 6 builds the duplicate pipeline on it.
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
}
