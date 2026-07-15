import SwiftUI
import PolyShelfCore

/// Duplicates smart view (FR-10.1): report-only groups of content-identical
/// files. Deleting stays in Finder via the reveal action.
struct DuplicatesView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var groups: [DuplicateGroup] = []
    @State private var scanning = false
    @State private var scanned = false

    var body: some View {
        Group {
            if scanning {
                ProgressView("Comparing file contents…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if groups.isEmpty {
                ContentUnavailableView {
                    Label(scanned ? "No Duplicates" : "Find Duplicates",
                          systemImage: "doc.on.doc")
                } description: {
                    Text(scanned
                        ? "No content-identical files in your library."
                        : "Compare all files by content hash to find identical models stored in different places.")
                } actions: {
                    if !scanned {
                        Button("Scan for Duplicates") { scan() }
                            .buttonStyle(.borderedProminent)
                    }
                }
            } else {
                List {
                    ForEach(groups) { group in
                        Section {
                            ForEach(group.items) { item in
                                HStack {
                                    ThumbnailView(item: item)
                                        .frame(width: 44, height: 44)
                                    VStack(alignment: .leading) {
                                        Text(item.effectiveName)
                                        Text(item.relPath)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button("Reveal") { reveal(item) }
                                        .controlSize(.small)
                                }
                            }
                        } header: {
                            Text("\(group.items.count) copies · \(ByteCountFormatter.string(fromByteCount: group.items[0].sizeBytes, countStyle: .file))")
                        }
                    }
                }
            }
        }
        .navigationSubtitle(groups.isEmpty ? "" : "\(groups.count) duplicate groups")
        .toolbar {
            ToolbarItem {
                Button {
                    scan()
                } label: {
                    Label("Rescan Duplicates", systemImage: "arrow.clockwise")
                }
                .disabled(scanning)
            }
        }
    }

    private func scan() {
        scanning = true
        let finder = DuplicateFinder(database: env.database, folderManager: env.libraryModel.folderManager)
        Task {
            groups = (try? await finder.findDuplicates()) ?? []
            scanning = false
            scanned = true
        }
    }

    private func reveal(_ item: ItemRecord) {
        Task {
            guard let access = try? await env.libraryModel.itemStore.beginFileAccess(
                item: item, folderManager: env.libraryModel.folderManager
            ) else { return }
            NSWorkspace.shared.activateFileViewerSelecting([access.file])
            access.root.stopAccessingSecurityScopedResource()
        }
    }
}
