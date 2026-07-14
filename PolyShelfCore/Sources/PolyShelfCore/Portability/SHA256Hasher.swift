import Foundation
import CryptoKit
import GRDB

/// Lazy SHA-256 (FR-2.2): computed on first need (export identity, dedupe),
/// streamed in 1 MB chunks, persisted back to the item row.
public enum SHA256Hasher {
    public static func hashFile(at url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            guard let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Ensures the item has a stored SHA-256, computing it if the file is
    /// reachable. Returns nil when the file can't be read (missing/offline).
    public static func ensureSHA256(
        item: ItemRecord,
        rootURL: URL,
        database: DatabaseManager
    ) async -> String? {
        if let existing = item.sha256 { return existing }
        guard let itemId = item.id else { return nil }
        let fileURL = rootURL.appendingPathComponent(item.relPath)
        guard let sha = try? hashFile(at: fileURL) else { return nil }
        try? await database.writer.write { db in
            try db.execute(sql: "UPDATE items SET sha256 = ? WHERE id = ?", arguments: [sha, itemId])
        }
        return sha
    }
}
