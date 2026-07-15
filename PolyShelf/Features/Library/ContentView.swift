import SwiftUI
import UniformTypeIdentifiers
import PolyShelfCore

enum SidebarSelection: Hashable {
    case allModels
    case folder(Int64)
    case tag(Int64)
    case missingOffline
    case duplicates
    case savedSearch(Int64)
}

struct ContentView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var folders: [FolderRecord] = []
    @State private var selection: SidebarSelection? = .allModels

    private var activeFolders: [FolderRecord] {
        folders.filter { $0.detachedAt == nil }
    }

    var body: some View {
        @Bindable var model = env.libraryModel
        Group {
            if activeFolders.isEmpty {
                OnboardingView()
            } else {
                NavigationSplitView {
                    SidebarView(folders: activeFolders, selection: $selection)
                } detail: {
                    if selection == .duplicates {
                        DuplicatesView()
                    } else {
                        LibraryGridView(selection: selection ?? .allModels)
                    }
                }
            }
        }
        .task { await observeFolders() }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers)
        }
        .alert(
            "Poly Shelf",
            isPresented: Binding(
                get: { model.alertMessage != nil },
                set: { if !$0 { model.alertMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.alertMessage ?? "")
        }
        .toolbar {
            ToolbarItem {
                Button {
                    env.libraryModel.presentAddFolderPanel()
                } label: {
                    Label("Add Folder…", systemImage: "plus")
                }
            }
            ToolbarItem {
                Button {
                    env.libraryModel.rescanAll(folders: activeFolders)
                } label: {
                    Label("Rescan All", systemImage: "arrow.clockwise")
                }
                .disabled(activeFolders.isEmpty)
            }
        }
    }

    private func observeFolders() async {
        let observation = ValueObservation.tracking { db in
            try FolderRecord.fetchAll(db)
        }
        do {
            for try await folders in observation.values(in: env.database.writer) {
                self.folders = folders
            }
        } catch {
            // Observation only fails if the database is unusable; surfaced at launch.
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            handled = true
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                    Task { @MainActor in
                        env.libraryModel.addFolder(at: url)
                    }
                }
            }
        }
        return handled
    }
}

struct SidebarView: View {
    @Environment(AppEnvironment.self) private var env
    let folders: [FolderRecord]
    @Binding var selection: SidebarSelection?
    @State private var folderPendingRemoval: FolderRecord?
    @State private var tagCounts: [TagCount] = []
    @State private var savedSearches: [SavedSearch] = []
    @State private var tagPendingRename: TagCount?
    @State private var renameDraft = ""

    var body: some View {
        List(selection: $selection) {
            Section("Library") {
                Label("All Models", systemImage: "square.grid.2x2")
                    .tag(SidebarSelection.allModels)
                Label("Missing & Offline", systemImage: "questionmark.folder")
                    .tag(SidebarSelection.missingOffline)
                Label("Duplicates", systemImage: "doc.on.doc")
                    .tag(SidebarSelection.duplicates)
            }
            if !savedSearches.isEmpty {
                Section("Saved Searches") {
                    ForEach(savedSearches) { saved in
                        Label(saved.name, systemImage: "folder.badge.gearshape")
                            .tag(SidebarSelection.savedSearch(saved.id!))
                            .contextMenu {
                                Button("Delete", role: .destructive) {
                                    deleteSavedSearch(saved)
                                }
                            }
                    }
                }
            }
            Section("Folders") {
                ForEach(folders) { folder in
                    Label {
                        Text(folder.displayName)
                    } icon: {
                        if env.libraryModel.scanningFolderIds.contains(folder.id ?? -1) {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "folder")
                        }
                    }
                    .tag(SidebarSelection.folder(folder.id!))
                    .contextMenu {
                        Button("Rescan") {
                            if let id = folder.id { env.libraryModel.rescan(folderId: id) }
                        }
                        Button("Reveal in Finder") {
                            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folder.pathHint)
                        }
                        Button("Export Folder Metadata…") {
                            if let id = folder.id {
                                env.libraryModel.exportMetadata(folderId: id, suggestedName: folder.displayName)
                            }
                        }
                        Button("Export Folder as Bundle…") {
                            if let id = folder.id {
                                env.libraryModel.exportBundle(folderId: id, suggestedName: folder.displayName)
                            }
                        }
                        Divider()
                        Button("Remove from Library…", role: .destructive) {
                            folderPendingRemoval = folder
                        }
                    }
                }
            }
            Section("Tags") {
                ForEach(tagCounts.prefix(30)) { tag in
                    Label {
                        HStack {
                            Text(tag.name)
                            Spacer()
                            Text("\(tag.count)")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                        }
                    } icon: {
                        Image(systemName: "tag")
                    }
                    .tag(SidebarSelection.tag(tag.tagId))
                    .contextMenu {
                        Button("Rename or Merge…") {
                            renameDraft = tag.name
                            tagPendingRename = tag
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .task { await observeTagCounts() }
        .task { await observeSavedSearches() }
        .alert(
            "Rename Tag",
            isPresented: Binding(
                get: { tagPendingRename != nil },
                set: { if !$0 { tagPendingRename = nil } }
            )
        ) {
            TextField("Tag name", text: $renameDraft)
            Button("Rename") {
                if let tag = tagPendingRename {
                    Task {
                        try? await TagStore(database: env.database)
                            .renameTag(tagId: tag.tagId, to: renameDraft)
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Renaming to an existing tag’s name merges the two tags.")
        }
        .confirmationDialog(
            "Remove “\(folderPendingRemoval?.displayName ?? "")” from your library?",
            isPresented: Binding(
                get: { folderPendingRemoval != nil },
                set: { if !$0 { folderPendingRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Keep Metadata") {
                if let id = folderPendingRemoval?.id {
                    env.libraryModel.removeFolder(id: id, keepMetadata: true)
                }
            }
            Button("Discard Metadata", role: .destructive) {
                if let id = folderPendingRemoval?.id {
                    env.libraryModel.removeFolder(id: id, keepMetadata: false)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Files on disk are never touched. Kept metadata (tags, display names) re-attaches if you add the folder again.")
        }
    }

    private func observeTagCounts() async {
        let enabled = env.libraryModel.enabledExtensions
        let observation = ValueObservation.tracking { db in
            try TagStore.tagCountsRequest(db, enabledExtensions: enabled)
        }
        do {
            // Conflate + pace: this aggregate query re-runs on every item/tag
            // write, which is constant churn during a scan.
            for try await counts in observation.values(
                in: env.database.writer, bufferingPolicy: .bufferingNewest(1)
            ) {
                tagCounts = counts
                try? await Task.sleep(nanoseconds: 300_000_000)
                if Task.isCancelled { break }
            }
        } catch {}
    }

    private func observeSavedSearches() async {
        let observation = ValueObservation.tracking { db in
            try SavedSearch.order(Column("name")).fetchAll(db)
        }
        do {
            for try await searches in observation.values(in: env.database.writer) {
                savedSearches = searches
            }
        } catch {}
    }

    private func deleteSavedSearch(_ saved: SavedSearch) {
        Task {
            _ = try? await env.database.writer.write { db in
                try SavedSearch.deleteOne(db, key: saved.id)
            }
        }
    }
}
