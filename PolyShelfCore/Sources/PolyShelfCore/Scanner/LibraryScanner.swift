import Foundation
import GRDB

public struct ScanSummary: Sendable, Equatable {
    public var discovered = 0
    public var added = 0
    public var updated = 0
    public var unchanged = 0
    public var markedMissing = 0
    public var failed = 0
}

public enum ScanError: Error, Equatable {
    case folderNotFound
    case folderOffline
    case bookmarkInvalid
}

/// A post-scan stage run over new/changed items while the scanner still holds
/// security-scoped access to the root (geometry parsing in M3, tagging in M5).
public protocol ScanEnrichmentStage: Sendable {
    func enrich(itemIds: [Int64], rootURL: URL) async
}

/// Metadata scan pass (FR-2.1–2.3): recursive discovery, incremental
/// (size+mtime) change detection, xxHash64 hashing, status transitions.
/// Geometry parsing and tagging are separate enrichment stages layered on
/// in later milestones via `ItemEnricher`.
public final class LibraryScanner: Sendable {
    /// Hook for M3+/M5 enrichment (geometry stats, auto-tags) applied to
    /// newly added or content-changed items, batched, off the scan path.
    public typealias ItemEnricher = @Sendable (_ itemIds: [Int64]) async -> Void

    private let database: DatabaseManager
    private let folderManager: FolderManager
    private let enrichmentStages: [any ScanEnrichmentStage]
    private let batchSize = 100

    public init(
        database: DatabaseManager,
        folderManager: FolderManager,
        enrichmentStages: [any ScanEnrichmentStage] = []
    ) {
        self.database = database
        self.folderManager = folderManager
        self.enrichmentStages = enrichmentStages
    }

    /// Scans one root folder. Never blocks the main thread (call from a Task);
    /// respects task cancellation between files. Progressive: items are
    /// committed in batches so observers update as the scan runs.
    @discardableResult
    public func scan(
        folderId: Int64,
        enabledExtensions: Set<String>,
        onProgress: (@Sendable (ScanSummary) -> Void)? = nil
    ) async throws -> ScanSummary {
        guard let folder: FolderRecord = try await database.writer.read({ db in
            try FolderRecord.fetchOne(db, key: folderId)
        }) else {
            throw ScanError.folderNotFound
        }

        switch folderManager.beginAccess(folder) {
        case .invalid:
            throw ScanError.bookmarkInvalid
        case .offline:
            try await markAll(folderId: folderId, status: .offline)
            throw ScanError.folderOffline
        case .available(let rootURL):
            defer { rootURL.stopAccessingSecurityScopedResource() }
            return try await scanRoot(rootURL, folder: folder, enabledExtensions: enabledExtensions, onProgress: onProgress)
        }
    }

    private func scanRoot(
        _ rootURL: URL,
        folder: FolderRecord,
        enabledExtensions: Set<String>,
        onProgress: (@Sendable (ScanSummary) -> Void)?
    ) async throws -> ScanSummary {
        let folderId = folder.id!
        var summary = ScanSummary()

        // Existing rows keyed by relPath for incremental comparison.
        var existing: [String: ItemRecord] = try await database.writer.read { db in
            let rows = try ItemRecord.filter(Column("folderId") == folderId).fetchAll(db)
            return Dictionary(uniqueKeysWithValues: rows.map { ($0.relPath, $0) })
        }
        var seenRelPaths = Set<String>()
        var pendingInserts: [ItemRecord] = []
        var pendingUpdates: [ItemRecord] = []
        var changedItemIds: [Int64] = []

        // Rename detection (FR-2.4): index not-yet-seen rows by inode and by
        // (hash, size) so a renamed/moved file keeps its item + metadata.
        var unseenByInode: [Int64: String] = [:] // inode → relPath key into `existing`
        for (relPath, row) in existing {
            if let inode = row.inode { unseenByInode[inode] = relPath }
        }
        var unseenByContent: [String: String] = [:] // "hash-size" → relPath
        for (relPath, row) in existing {
            if let hash = row.xxhash64 {
                unseenByContent["\(hash)-\(row.sizeBytes)"] = relPath
            }
        }

        let keys: [URLResourceKey] = [
            .isRegularFileKey, .fileSizeKey,
            .contentModificationDateKey, .creationDateKey,
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw ScanError.folderOffline
        }

        let rootPath = rootURL.standardizedFileURL.path

        for case let fileURL as URL in enumerator {
            try Task.checkCancellation()

            guard let values = try? fileURL.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }
            let ext = fileURL.pathExtension.lowercased()
            guard enabledExtensions.contains(ext) else { continue }

            let filePath = fileURL.standardizedFileURL.path
            guard filePath.hasPrefix(rootPath + "/") else { continue }
            let relPath = String(filePath.dropFirst(rootPath.count + 1))
            seenRelPaths.insert(relPath)
            summary.discovered += 1

            let size = Int64(values.fileSize ?? 0)
            let modified = values.contentModificationDate
            let created = values.creationDate
            let inode = Self.inode(of: filePath)

            if var row = existing[relPath] {
                let contentUnchanged = row.sizeBytes == size && Self.datesMatch(row.modifiedAt, modified)
                if contentUnchanged && row.status == .ok {
                    summary.unchanged += 1
                    continue
                }
                // Changed on disk, or coming back from missing/offline/unreadable.
                if !contentUnchanged {
                    do {
                        row.xxhash64 = Int64(bitPattern: try XXHash64.hashFile(at: fileURL))
                        row.sha256 = nil // stale; recomputed lazily on demand
                    } catch {
                        summary.failed += 1
                        continue
                    }
                }
                row.sizeBytes = size
                row.modifiedAt = modified
                row.createdAt = created
                row.inode = inode
                row.status = .ok
                row.missingSince = nil
                row.indexedAt = Date()
                pendingUpdates.append(row)
                existing[relPath] = row
                summary.updated += 1
            } else {
                let hash: Int64?
                do {
                    hash = Int64(bitPattern: try XXHash64.hashFile(at: fileURL))
                } catch {
                    summary.failed += 1
                    continue
                }

                // Rename/move detection: same inode, or same content
                // (hash+size), on a row whose old path no longer exists →
                // update in place, keeping tags and display name (FR-2.4).
                var oldRelPath: String?
                if let inode, let candidate = unseenByInode[inode],
                   !seenRelPaths.contains(candidate), existing[candidate] != nil {
                    oldRelPath = candidate
                } else if let hash, let candidate = unseenByContent["\(hash)-\(size)"],
                          !seenRelPaths.contains(candidate), existing[candidate] != nil,
                          !FileManager.default.fileExists(atPath: rootPath + "/" + candidate) {
                    // Content match only counts as a rename if the old path is
                    // really gone (otherwise it's a duplicate copy).
                    oldRelPath = candidate
                }

                if let oldRelPath, var row = existing[oldRelPath] {
                    row.relPath = relPath
                    row.originalName = fileURL.lastPathComponent
                    row.ext = ext
                    row.sizeBytes = size
                    row.modifiedAt = modified
                    row.createdAt = created
                    row.xxhash64 = hash
                    row.inode = inode
                    row.status = .ok
                    row.missingSince = nil
                    row.indexedAt = Date()
                    pendingUpdates.append(row)
                    existing.removeValue(forKey: oldRelPath)
                    existing[relPath] = row
                    seenRelPaths.insert(oldRelPath) // old path is accounted for
                    summary.updated += 1
                } else {
                    let row = ItemRecord(
                        folderId: folderId,
                        relPath: relPath,
                        originalName: fileURL.lastPathComponent,
                        ext: ext,
                        sizeBytes: size,
                        createdAt: created,
                        modifiedAt: modified,
                        xxhash64: hash,
                        inode: inode,
                        status: .ok
                    )
                    pendingInserts.append(row)
                    summary.added += 1
                }
            }

            if pendingInserts.count + pendingUpdates.count >= batchSize {
                let ids = try await flush(inserts: &pendingInserts, updates: &pendingUpdates)
                changedItemIds.append(contentsOf: ids)
                onProgress?(summary)
            }
        }

        let ids = try await flush(inserts: &pendingInserts, updates: &pendingUpdates)
        changedItemIds.append(contentsOf: ids)

        // Anything indexed before but not seen now → missing (FR edge case:
        // metadata retained; purge is a separate, user-driven action).
        let missingRelPaths = Set(existing.keys).subtracting(seenRelPaths)
        if !missingRelPaths.isEmpty {
            let missingIds = missingRelPaths.compactMap { existing[$0]?.id }
            summary.markedMissing = missingIds.count
            try await database.writer.write { db in
                for id in missingIds {
                    try db.execute(
                        sql: """
                            UPDATE items
                            SET status = ?, missingSince = COALESCE(missingSince, ?)
                            WHERE id = ? AND status != ?
                            """,
                        arguments: [ItemStatus.missing.rawValue, Date(), id, ItemStatus.missing.rawValue]
                    )
                }
            }
        }

        onProgress?(summary)

        // Enrichment (geometry stats, auto-tags) over new/changed items,
        // while we still hold security-scoped access to the root.
        for stage in enrichmentStages {
            try Task.checkCancellation()
            await stage.enrich(itemIds: changedItemIds, rootURL: rootURL)
        }

        return summary
    }

    private func flush(
        inserts: inout [ItemRecord],
        updates: inout [ItemRecord]
    ) async throws -> [Int64] {
        guard !inserts.isEmpty || !updates.isEmpty else { return [] }
        let toInsert = inserts
        let toUpdate = updates
        inserts.removeAll()
        updates.removeAll()
        return try await database.writer.write { db in
            var ids: [Int64] = []
            for var row in toInsert {
                try row.insert(db)
                ids.append(row.id!)
            }
            for row in toUpdate {
                try row.update(db)
                if let id = row.id { ids.append(id) }
            }
            try DatabaseManager.refreshFTS(db, itemIds: ids)
            return ids
        }
    }

    /// SQLite stores dates at millisecond precision while APFS mtimes carry
    /// nanoseconds — exact equality would re-hash every file on every scan.
    static func datesMatch(_ a: Date?, _ b: Date?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (a?, b?): return abs(a.timeIntervalSince(b)) < 0.002
        default: return false
        }
    }

    /// File inode via lstat — survives on-disk renames (rename matching, FR-2.4).
    static func inode(of path: String) -> Int64? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        return Int64(bitPattern: UInt64(st.st_ino))
    }

    private func markAll(folderId: Int64, status: ItemStatus) async throws {
        try await database.writer.write { db in
            try db.execute(
                sql: "UPDATE items SET status = ? WHERE folderId = ? AND status = ?",
                arguments: [status.rawValue, folderId, ItemStatus.ok.rawValue]
            )
        }
    }
}
