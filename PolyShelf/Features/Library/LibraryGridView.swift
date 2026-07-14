import SwiftUI
import PolyShelfCore

/// Grid of indexed items for the current sidebar selection with instant
/// search, filters, and sorts (FR-8.x). Observes the database directly, so
/// items appear progressively while a scan runs.
struct LibraryGridView: View {
    @Environment(AppEnvironment.self) private var env
    let selection: SidebarSelection

    @State private var items: [ItemRecord] = []
    @State private var selectedItemId: Int64?
    @State private var searchText = ""
    @State private var sort: LibraryQuery.SortKey = .name
    @State private var sortDescending = false
    @State private var filterTagIds: Set<Int64> = []
    @State private var filterFormats: Set<String> = []
    @State private var addedWithinDays: Int? = nil
    @State private var allTags: [TagCount] = []

    private let columns = [GridItem(.adaptive(minimum: 160, maximum: 220), spacing: 16)]

    private var selectedItem: ItemRecord? {
        guard let selectedItemId else { return nil }
        return items.first { $0.id == selectedItemId }
    }

    /// A selected saved search replaces the whole query (it captured its own
    /// search text, filters, and sort when saved).
    @State private var loadedSavedQuery: LibraryQuery?

    private var query: LibraryQuery {
        if case .savedSearch = selection, let loadedSavedQuery {
            return loadedSavedQuery
        }
        var q = LibraryQuery()
        q.scope = switch selection {
        case .allModels, .savedSearch: .all
        case .folder(let id): .folder(id)
        case .missingOffline: .missingOffline
        case .tag(let id): .tag(id)
        case .duplicates: .all // duplicates render in their own view
        }
        q.searchText = searchText
        let enabled = env.libraryModel.enabledExtensions
        q.formats = filterFormats.isEmpty ? enabled : enabled.intersection(filterFormats)
        q.requiredTagIds = Array(filterTagIds).sorted()
        if let days = addedWithinDays {
            q.addedAfter = Calendar.current.date(byAdding: .day, value: -days, to: Date())
        }
        q.sort = sort
        q.sortDescending = sortDescending
        return q
    }

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            grid
        }
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search names, tags, notes…")
        .navigationSubtitle("\(items.count) models")
        .toolbar { sortMenu }
        .inspector(isPresented: Binding(
            get: { selectedItem != nil },
            set: { if !$0 { selectedItemId = nil } }
        )) {
            if let selectedItem {
                DetailView(item: selectedItem)
                    .inspectorColumnWidth(min: 280, ideal: 340, max: 480)
            }
        }
        .task(id: selection) { await loadSavedQueryIfNeeded() }
        .task(id: query) { await observeItems() }
        .alert("Save Search", isPresented: $showingSaveSearch) {
            TextField("Name", text: $saveSearchName)
            Button("Save") { saveCurrentSearch() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saves the current search text, filters, and sort as a smart folder.")
        }
    }

    // MARK: - Saved searches (FR-8.5)

    @State private var showingSaveSearch = false
    @State private var saveSearchName = ""

    private func loadSavedQueryIfNeeded() async {
        guard case .savedSearch(let id) = selection else {
            loadedSavedQuery = nil
            return
        }
        loadedSavedQuery = try? await env.database.writer.read { db in
            try SavedSearch.fetchOne(db, key: id)?.query
        }
    }

    private func saveCurrentSearch() {
        let name = saveSearchName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let current = query
        Task {
            _ = try? await env.database.writer.write { db in
                var record = try SavedSearch(name: name, query: current)
                try record.insert(db)
            }
        }
        saveSearchName = ""
    }

    @ViewBuilder
    private var grid: some View {
        if items.isEmpty {
            ContentUnavailableView(
                searchText.isEmpty ? "No Models" : "No Results",
                systemImage: searchText.isEmpty ? "cube.transparent" : "magnifyingglass",
                description: Text(searchText.isEmpty
                    ? "Models will appear here as folders are scanned."
                    : "No models match “\(searchText)”.")
            )
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(items) { item in
                        ItemCell(item: item, isSelected: item.id == selectedItemId)
                            .onTapGesture {
                                selectedItemId = (selectedItemId == item.id) ? nil : item.id
                            }
                    }
                }
                .padding(16)
            }
        }
    }

    // MARK: - Filter bar (FR-8.3)

    private var filterBar: some View {
        HStack(spacing: 12) {
            Menu {
                ForEach(allTags.prefix(40)) { tag in
                    Toggle("\(tag.name) (\(tag.count))", isOn: Binding(
                        get: { filterTagIds.contains(tag.tagId) },
                        set: { on in
                            if on { filterTagIds.insert(tag.tagId) } else { filterTagIds.remove(tag.tagId) }
                        }
                    ))
                }
                if !filterTagIds.isEmpty {
                    Divider()
                    Button("Clear Tag Filter") { filterTagIds.removeAll() }
                }
            } label: {
                Label(
                    filterTagIds.isEmpty ? "Tags" : "Tags (\(filterTagIds.count))",
                    systemImage: "tag"
                )
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Menu {
                ForEach(FormatRegistry.all.filter { env.libraryModel.enabledExtensions.contains($0.ext) }, id: \.ext) { spec in
                    Toggle(".\(spec.ext)", isOn: Binding(
                        get: { filterFormats.contains(spec.ext) },
                        set: { on in
                            if on { filterFormats.insert(spec.ext) } else { filterFormats.remove(spec.ext) }
                        }
                    ))
                }
                if !filterFormats.isEmpty {
                    Divider()
                    Button("All Formats") { filterFormats.removeAll() }
                }
            } label: {
                Label(
                    filterFormats.isEmpty ? "Format" : filterFormats.sorted().map { ".\($0)" }.joined(separator: " "),
                    systemImage: "doc"
                )
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Menu {
                Button("Any Time") { addedWithinDays = nil }
                Button("Last 24 Hours") { addedWithinDays = 1 }
                Button("Last Week") { addedWithinDays = 7 }
                Button("Last Month") { addedWithinDays = 30 }
            } label: {
                Label(dateFilterLabel, systemImage: "calendar")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    private var dateFilterLabel: String {
        switch addedWithinDays {
        case nil: "Added"
        case 1: "Last 24h"
        case 7: "Last Week"
        case 30: "Last Month"
        default: "Last \(addedWithinDays!)d"
        }
    }

    private var sortMenu: some ToolbarContent {
        ToolbarItem {
            Menu {
                Button("Save Current Search…") {
                    showingSaveSearch = true
                }
                .disabled(searchText.isEmpty && filterTagIds.isEmpty && filterFormats.isEmpty && addedWithinDays == nil)
                Divider()
                Picker("Sort By", selection: $sort) {
                    ForEach(LibraryQuery.SortKey.allCases, id: \.self) { key in
                        Text(key.rawValue).tag(key)
                    }
                }
                Divider()
                Toggle("Descending", isOn: $sortDescending)
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
            }
        }
    }

    // MARK: - Observation

    private func observeItems() async {
        let query = self.query
        let observation = ValueObservation.tracking { db -> ([ItemRecord], [TagCount]) in
            let items = try LibraryQuery.fetch(db, query: query)
            let tags = try TagStore.tagCountsRequest(db, enabledExtensions: query.formats)
            return (items, tags)
        }
        do {
            for try await (items, tags) in observation.values(in: env.database.writer) {
                self.items = items
                self.allTags = tags
            }
        } catch {
            // DB unusable — surfaced at launch.
        }
    }
}

struct ItemCell: View {
    let item: ItemRecord
    var isSelected = false
    @Environment(AppEnvironment.self) private var env
    @State private var isRenaming = false
    @State private var draftName = ""
    @FocusState private var renameFocused: Bool

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                ThumbnailView(item: item)
                    .aspectRatio(1, contentMode: .fit)
                if item.status != .ok {
                    VStack {
                        Spacer()
                        HStack {
                            statusBadge
                            Spacer()
                        }
                    }
                    .padding(6)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 3)
            )

            // Display name with Finder-like inline rename (FR-6.2) — writes
            // ONLY to the database, never to disk.
            if isRenaming {
                TextField("Name", text: $draftName)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout)
                    .focused($renameFocused)
                    .onSubmit { commitRename() }
                    .onExitCommand { isRenaming = false }
                    .onChange(of: renameFocused) {
                        if !renameFocused { commitRename() }
                    }
            } else {
                Text(item.effectiveName)
                    .font(.callout)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .onTapGesture(count: 2) { beginRename() }
            }

            Text(".\(item.ext) · \(ByteCountFormatter.string(fromByteCount: item.sizeBytes, countStyle: .file))")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .help(item.originalName)
        .contextMenu {
            Button("Rename…") { beginRename() }
            if item.displayName != nil {
                Button("Clear Display Name") {
                    Task { try? await env.libraryModel.itemStore.setDisplayName(nil, itemId: item.id!) }
                }
            }
        }
    }

    private func beginRename() {
        draftName = item.effectiveName
        isRenaming = true
        renameFocused = true
    }

    private func commitRename() {
        guard isRenaming else { return }
        isRenaming = false
        let name = draftName
        guard name != item.effectiveName, let itemId = item.id else { return }
        Task {
            // Setting the display name to the original name clears it.
            let value = (name == item.originalName) ? nil : name
            try? await env.libraryModel.itemStore.setDisplayName(value, itemId: itemId)
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch item.status {
        case .missing:
            Label("Missing", systemImage: "exclamationmark.triangle.fill")
                .font(.caption2).padding(4)
                .background(.yellow.opacity(0.85), in: Capsule())
        case .offline:
            Label("Offline", systemImage: "externaldrive.badge.xmark")
                .font(.caption2).padding(4)
                .background(.gray.opacity(0.85), in: Capsule())
        case .unreadable:
            Label("Unreadable", systemImage: "questionmark.diamond.fill")
                .font(.caption2).padding(4)
                .background(.orange.opacity(0.85), in: Capsule())
        case .ok:
            EmptyView()
        }
    }
}
