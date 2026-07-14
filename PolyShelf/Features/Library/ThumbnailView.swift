import SwiftUI
import PolyShelfCore

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
        .task(id: item.id) { loadFromCache() }
        .onReceive(NotificationCenter.default.publisher(for: .polyShelfThumbnailReady)) { note in
            if image == nil, note.userInfo?["key"] as? String == cacheKey {
                loadFromCache()
            }
        }
    }

    private func loadFromCache() {
        guard image == nil, let key = cacheKey,
              let data = env.libraryModel.thumbnailCache.data(forKey: key) else { return }
        image = NSImage(data: data)
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
