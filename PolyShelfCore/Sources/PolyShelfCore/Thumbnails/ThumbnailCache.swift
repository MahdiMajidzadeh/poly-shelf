import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Disk cache of 512×512 PNG thumbnails in Application Support, keyed by
/// content hash (FR-4.1) — a re-downloaded identical file reuses its
/// thumbnail. LRU-evicted above a size cap (default 2 GB, §10 Q2).
public final class ThumbnailCache: @unchecked Sendable {
    public let directory: URL
    private let maxBytes: Int64
    /// Hot-path memory layer so grid cells recycled during scroll don't
    /// re-read PNGs from disk. NSCache is thread-safe and evicts under pressure.
    private let memoryCache = NSCache<NSString, NSData>()

    public init(directory: URL, maxBytes: Int64 = 2 * 1024 * 1024 * 1024) throws {
        self.directory = directory
        self.maxBytes = maxBytes
        memoryCache.totalCostLimit = 64 * 1024 * 1024
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public static func defaultCache() throws -> ThumbnailCache {
        let dir = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ).appendingPathComponent("PolyShelf/Thumbnails", isDirectory: true)
        return try ThumbnailCache(directory: dir)
    }

    /// Content-hash key: eager xxHash64 + size. Stable across path/name
    /// changes; aliased automatically for identical content.
    public static func key(xxhash64: Int64, sizeBytes: Int64) -> String {
        String(format: "%016llx-%llx", UInt64(bitPattern: xxhash64), sizeBytes)
    }

    public static func key(for item: ItemRecord) -> String? {
        guard let hash = item.xxhash64 else { return nil }
        return key(xxhash64: hash, sizeBytes: item.sizeBytes)
    }

    public func fileURL(forKey key: String) -> URL {
        directory.appendingPathComponent("\(key).png")
    }

    public func contains(key: String) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(forKey: key).path)
    }

    public func data(forKey key: String) -> Data? {
        if let cached = memoryCache.object(forKey: key as NSString) {
            return cached as Data
        }
        guard let data = try? Data(contentsOf: fileURL(forKey: key)) else { return nil }
        memoryCache.setObject(data as NSData, forKey: key as NSString, cost: data.count)
        return data
    }

    /// Stores PNG data; any ImageIO-decodable input (BMP from .gx, arbitrary
    /// PNG sizes) is normalized to a ≤512px PNG.
    public func store(imageData: Data, forKey key: String) {
        guard let normalized = Self.normalizedPNG(from: imageData, maxPixel: 512) else { return }
        try? normalized.write(to: fileURL(forKey: key), options: .atomic)
        memoryCache.setObject(normalized as NSData, forKey: key as NSString, cost: normalized.count)
        pruneIfNeeded()
    }

    /// Decode + downscale + re-encode as PNG. Returns nil for undecodable data.
    static func normalizedPNG(from data: Data, maxPixel: Int) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let output = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return output as Data
    }

    // MARK: - LRU eviction

    /// Cheap probabilistic prune: full directory walk only ~1 in 50 stores.
    private func pruneIfNeeded() {
        guard Int.random(in: 0..<50) == 0 else { return }
        prune()
    }

    public func prune() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentAccessDateKey]
        ) else { return }

        var entries: [(url: URL, size: Int64, accessed: Date)] = []
        var total: Int64 = 0
        for url in files {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentAccessDateKey])
            let size = Int64(values?.fileSize ?? 0)
            total += size
            entries.append((url, size, values?.contentAccessDate ?? .distantPast))
        }
        guard total > maxBytes else { return }

        // Evict least-recently-accessed until 10% under the cap.
        let target = maxBytes * 9 / 10
        for entry in entries.sorted(by: { $0.accessed < $1.accessed }) {
            guard total > target else { break }
            try? fm.removeItem(at: entry.url)
            total -= entry.size
        }
    }
}
