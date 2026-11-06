import CoreGraphics
import Foundation
import GRDB
import ImageIO

/// Makes the perceptual hash of an image file. It reads content, so it is only ever given a file that is on disk.
public protocol ImageFingerprinter: Sendable {
    /// Bumped when the algorithm changes, so every fingerprint is made again.
    var algorithm: Int { get }
    func fingerprint(path: String) throws -> UInt64
}

/// 64-bit difference hash: the image is shrunk to 9x8 grey pixels and each bit says whether a pixel is brighter than
/// its right neighbour. Resizes, re-encodes and small colour or compression changes move few bits, so two images of the
/// same picture differ in a handful of bits (ADR 0007, 0015).
public struct DifferenceHasher: ImageFingerprinter {
    public let algorithm = 1
    public init() {}

    public func fingerprint(path: String) throws -> UInt64 {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: 128,
              ] as CFDictionary) else { throw ThumbnailRenderError.unreadable(path) }
        return try Self.hash(of: image, path: path)
    }

    static func hash(of image: CGImage, path: String = "image") throws -> UInt64 {
        let width = 9, height = 8
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .high
            // Transparent pixels would otherwise read as black.
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw ThumbnailRenderError.unreadable(path) }
        var hash: UInt64 = 0
        for row in 0..<height {
            for column in 0..<(width - 1) {
                hash <<= 1
                if pixels[row * width + column] > pixels[row * width + column + 1] { hash |= 1 }
            }
        }
        return hash
    }

    /// Number of differing bits between two hashes.
    public static func distance(_ a: UInt64, _ b: UInt64) -> Int { (a ^ b).nonzeroBitCount }
}

/// Computes a file's fingerprint. Never downloads, and stores nothing for a file that changed while it was read.
public struct FingerprintJobHandler: JobHandler {
    let library: Library
    let fileSystem: FileSystem
    let fingerprinter: any ImageFingerprinter

    public init(library: Library, fileSystem: FileSystem, fingerprinter: any ImageFingerprinter = DifferenceHasher()) {
        self.library = library
        self.fileSystem = fileSystem
        self.fingerprinter = fingerprinter
    }

    public func run(_ job: Job) async throws {
        guard let fileID = job.fileID, let file = try library.file(id: fileID), file.missingSince == nil,
              file.kind == FileKind.image.rawValue, file.icloudStatus == "local",
              let path = try? library.absolutePath(of: file, fileSystem: fileSystem) else { return }
        func unchanged() -> Bool {
            guard let live = try? fileSystem.metadata(at: path), !live.isDirectory, !live.isSymlink, !live.isDataless else { return false }
            return live.size == file.size && abs(live.modified.timeIntervalSince(file.modified)) < 0.01
        }
        guard unchanged() else { return }
        let hash = try fingerprinter.fingerprint(path: path)
        guard unchanged() else { return }
        try library.storeFingerprint(hash, algorithm: fingerprinter.algorithm, fileID: fileID, size: file.size, modified: file.modified)
    }
}

extension Library {
    func storeFingerprint(_ hash: UInt64, algorithm: Int, fileID: Int64, size: Int64, modified: Date) throws {
        try database.write { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO image_fingerprint (fileID, hash, algorithm, sourceSize, sourceModified, createdAt)
                SELECT id, ?, ?, ?, ?, ? FROM file WHERE id = ? AND size = ? AND modified = ? AND missingSince IS NULL
                """, arguments: [Int64(bitPattern: hash), algorithm, size, modified, Date(), fileID, size, modified])
        }
    }

    /// Queues a fingerprint for every local image that has none, or whose file or algorithm changed since.
    @discardableResult
    public func enqueueFingerprintJobs(rootID: Int64? = nil, algorithm: Int = DifferenceHasher().algorithm, now: Date = Date()) throws -> Int {
        try database.write { db in
            try db.execute(sql: """
                INSERT OR IGNORE INTO job (kind, fileID, state, attempts, createdAt, updatedAt)
                SELECT ?, f.id, 'queued', 0, ?, ? FROM file f
                LEFT JOIN image_fingerprint p ON p.fileID = f.id
                WHERE f.missingSince IS NULL AND f.icloudStatus = 'local' AND f.kind = 'image' AND f.size > 0
                  AND (p.fileID IS NULL OR p.algorithm <> ? OR p.sourceSize <> f.size OR p.sourceModified <> f.modified)
                  \(rootID == nil ? "" : "AND f.rootID = ?")
                ORDER BY f.id
                """, arguments: StatementArguments([JobKind.fingerprint.rawValue, now, now, algorithm] + (rootID.map { [DatabaseValueConvertible]([$0]) } ?? [])))
            return db.changesCount
        }
    }

    public func fingerprint(forFile fileID: Int64) throws -> UInt64? {
        try database.read { db in
            try Int64.fetchOne(db, sql: "SELECT hash FROM image_fingerprint WHERE fileID = ?", arguments: [fileID]).map { UInt64(bitPattern: $0) }
        }
    }

    // MARK: Near-duplicate groups

    /// Default distance (of 64 bits) up to which two images count as the same picture.
    public static let nearDuplicateDistance = 6

    /// Rebuilds the near-duplicate groups from the stored fingerprints (ADR 0007: suggestions only, never resolved
    /// automatically). A group is a set of live, local-or-evicted images whose hashes chain together within `maxDistance`
    /// bits and that are at least two different files on disk.
    ///
    /// Left out: a file and the resize Miles made from it (`file_link`, ADR 0006), hard links of one file (they count once),
    /// and sets whose members all have the same full hash (those are exact duplicates and belong to `dup list`).
    /// A group whose members are unchanged keeps its review status; a changed group is a new, open one.
    /// Returns the number of groups.
    @discardableResult
    public func refreshNearDuplicateGroups(maxDistance: Int = Library.nearDuplicateDistance, now: Date = Date()) throws -> Int {
        guard (0...16).contains(maxDistance) else { throw OperationError.refused("the near-duplicate distance must be between 0 and 16 bits") }
        return try database.write { db in
            struct Entry { var id: Int64; var identity: String; var hash: UInt64; var fullHash: Data? }
            let entries = try Row.fetchAll(db, sql: """
                SELECT f.id, f.volumeID || ':' || f.fileID AS identity, p.hash, f.fullHash FROM image_fingerprint p
                JOIN file f ON f.id = p.fileID WHERE f.missingSince IS NULL ORDER BY f.id
                """).map { Entry(id: $0["id"], identity: $0["identity"], hash: UInt64(bitPattern: $0["hash"] as Int64), fullHash: $0["fullHash"]) }

            // A file and its own resize: the original now lives in the holdback, but its hash can come back if a copy is restored.
            var linked: Set<[Int64]> = []
            for row in try Row.fetchAll(db, sql: """
                SELECT l.derivedFileID AS a, o.id AS b FROM file_link l JOIN file o ON o.fullHash = l.originalHash
                """) {
                let a: Int64 = row["a"], b: Int64 = row["b"]
                linked.insert([min(a, b), max(a, b)])
            }

            // Distinct hash values are the graph's nodes; files with the same value share a node.
            var nodeOfHash: [UInt64: Int] = [:]
            var hashes: [UInt64] = []
            var filesOfNode: [[Entry]] = []
            for entry in entries {
                if let node = nodeOfHash[entry.hash] { filesOfNode[node].append(entry) } else {
                    nodeOfHash[entry.hash] = hashes.count
                    hashes.append(entry.hash)
                    filesOfNode.append([entry])
                }
            }

            // Union-find over nodes. Two hashes within `maxDistance` bits share at least one of (maxDistance + 1) bands
            // by the pigeonhole principle, so only hashes sharing a band value are compared.
            var parent = Array(0..<hashes.count)
            func find(_ x: Int) -> Int {
                var x = x
                while parent[x] != x { parent[x] = parent[parent[x]]; x = parent[x] }
                return x
            }
            let bands = maxDistance + 1
            let bandBits = 64 / bands
            var buckets: [UInt64: [Int]] = [:]
            func key(_ hash: UInt64, band: Int) -> UInt64 {
                let low = band * bandBits
                let width = (band == bands - 1 ? 64 : low + bandBits) - low
                let slice = (hash >> UInt64(low)) & (width == 64 ? ~0 : (1 << UInt64(width)) - 1)
                return UInt64(band) << 58 ^ slice
            }
            for (node, hash) in hashes.enumerated() {
                for band in 0..<bands { buckets[key(hash, band: band), default: []].append(node) }
            }
            for nodes in buckets.values where nodes.count > 1 {
                for i in 0..<nodes.count {
                    for j in (i + 1)..<nodes.count where find(nodes[i]) != find(nodes[j]) {
                        guard DifferenceHasher.distance(hashes[nodes[i]], hashes[nodes[j]]) <= maxDistance else { continue }
                        // Linked files must not join a group through each other.
                        let pairs = filesOfNode[nodes[i]].flatMap { a in filesOfNode[nodes[j]].map { b in [min(a.id, b.id), max(a.id, b.id)] } }
                        if pairs.allSatisfy(linked.contains) { continue }
                        parent[find(nodes[i])] = find(nodes[j])
                    }
                }
            }

            var components: [Int: [Int]] = [:]
            for node in 0..<hashes.count { components[find(node), default: []].append(node) }

            var wanted: [[Int64]: [(id: Int64, similarity: Double)]] = [:]
            for nodes in components.values {
                let files = nodes.flatMap { filesOfNode[$0] }
                guard Set(files.map(\.identity)).count >= 2 else { continue }
                // Files with one hash value share a node, so a linked pair can still be in one component: it needs a pair that isn't.
                let hasUnlinkedPair = files.indices.contains { i in
                    files.indices.dropFirst(i + 1).contains { j in
                        files[i].identity != files[j].identity
                            && !linked.contains([min(files[i].id, files[j].id), max(files[i].id, files[j].id)])
                    }
                }
                guard hasUnlinkedPair else { continue }
                let fulls = Set(files.map(\.fullHash))
                if fulls.count == 1, fulls.first! != nil { continue }
                var seen: Set<String> = []
                var members: [(id: Int64, similarity: Double)] = []
                for file in files.sorted(by: { $0.id < $1.id }) where seen.insert(file.identity).inserted {
                    let closest = files.filter { $0.identity != file.identity }.map { DifferenceHasher.distance($0.hash, file.hash) }.min() ?? 0
                    members.append((file.id, 1 - Double(closest) / 64))
                }
                wanted[members.map(\.id)] = members
            }

            var keptGroups = 0
            var existing: [[Int64]: Int64] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT id FROM dup_group WHERE kind = 'near'") {
                let id: Int64 = row["id"]
                let ids = try Int64.fetchAll(db, sql: "SELECT fileID FROM dup_member WHERE groupID = ? ORDER BY fileID", arguments: [id])
                if wanted[ids] != nil, existing[ids] == nil { existing[ids] = id } else {
                    try db.execute(sql: "DELETE FROM dup_group WHERE id = ?", arguments: [id])
                }
            }
            for (ids, members) in wanted {
                if let id = existing[ids] {
                    for m in members {
                        try db.execute(sql: "UPDATE dup_member SET similarity = ? WHERE groupID = ? AND fileID = ?", arguments: [m.similarity, id, m.id])
                    }
                } else {
                    try db.execute(sql: "INSERT INTO dup_group (kind, contentHash, status, createdAt, updatedAt) VALUES ('near', NULL, 'open', ?, ?)",
                                   arguments: [now, now])
                    let id = db.lastInsertedRowID
                    for m in members {
                        try db.execute(sql: "INSERT INTO dup_member (groupID, fileID, similarity) VALUES (?, ?, ?)", arguments: [id, m.id, m.similarity])
                    }
                }
                keptGroups += 1
            }
            return keptGroups
        }
    }
}
