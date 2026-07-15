import SwiftUI
import ImageIO
import PolyShelfCore

/// Process-wide cache of *decoded* thumbnails. Without it every cell recycle
/// re-creates an NSImage whose PNG is decoded lazily — on the main thread, at
/// draw time, mid-scroll. Keyed by the content-hash cache key.
private enum DecodedThumbnails {
    static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.totalCostLimit = 128 * 1024 * 1024 // decoded RGBA bytes
        return cache
    }()
}

/// Cached-thumbnail image with format-icon placeholder; swaps in the PNG
/// when the pipeline announces it (placeholder → thumbnail, FR-4 acceptance).
struct ThumbnailView: View {
    let item: ItemRecord
    @Environment(AppEnvironment.self) private var env
    @State private var image: NSImage?

    private var cacheKey: String? { ThumbnailCache.key(for: item) }

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                RoundedRectangle(cornerRadius: 10)
                    .fill(.quaternary.opacity(0.5))
                Image(systemName: iconName)
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: item.id) { await loadFromCache() }
        .onReceive(NotificationCenter.default.publisher(for: .polyShelfThumbnailReady)) { note in
            if image == nil, note.userInfo?["key"] as? String == cacheKey {
                Task { await loadFromCache() }
            }
        }
    }

    private func loadFromCache() async {
        guard image == nil, let key = cacheKey else { return }
        if let cached = DecodedThumbnails.cache.object(forKey: key as NSString) {
            image = cached
            return
        }
        guard let decoded = await Self.loadAndDecode(env.libraryModel.thumbnailCache, key: key) else { return }
        DecodedThumbnails.cache.setObject(
            decoded, forKey: key as NSString,
            cost: Int(decoded.size.width * decoded.size.height) * 4
        )
        image = decoded
    }

    /// Nonisolated async → runs on the global executor: disk read AND pixel
    /// decode happen off the main thread (`ShouldCacheImmediately` forces the
    /// decode here instead of lazily at first draw).
    private nonisolated static func loadAndDecode(_ cache: ThumbnailCache, key: String) async -> NSImage? {
        guard let data = cache.data(forKey: key),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(
                  source, 0,
                  [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
              )
        else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    private var iconName: String {
        switch FormatRegistry.spec(forExtension: item.ext)?.group {
        case .printMesh, .universal: "cube"
        case .cad: "ruler"
        case .source: "hammer"
        case .slicerOutput: "printer"
        case .archive: "archivebox"
        case nil: "doc"
        }
    }
}
