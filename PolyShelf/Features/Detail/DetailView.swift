import SwiftUI
import SceneKit
import PolyShelfCore

/// Item detail panel (FR-7.1): interactive 3D viewer or large preview,
/// names, path with Reveal in Finder, stats, notes. Tag editing lands in M5.
struct DetailView: View {
    let item: ItemRecord
    @Environment(AppEnvironment.self) private var env
    @State private var scene: SCNScene?
    @State private var notesDraft = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                previewSection
                nameSection
                Divider()
                statsSection
                Divider()
                if let itemId = item.id {
                    TagEditorView(itemId: itemId)
                    aiSection(itemId: itemId)
                    Divider()
                }
                notesSection
                actionsSection
            }
            .padding(16)
        }
        .task(id: item.id) {
            notesDraft = item.notes ?? ""
            await loadSceneIfRenderable()
        }
    }

    // MARK: - Preview

    @ViewBuilder
    private var previewSection: some View {
        if let scene {
            SceneView(
                scene: scene,
                options: [.allowsCameraControl, .autoenablesDefaultLighting]
            )
            .frame(minHeight: 280)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        } else {
            ThumbnailView(item: item)
                .frame(minHeight: 220)
        }
    }

    private func loadSceneIfRenderable() async {
        scene = nil
        guard item.status == .ok,
              FormatRegistry.spec(forExtension: item.ext)?.interactive3D == true else { return }
        let currentItem = item
        let folderManager = env.libraryModel.folderManager
        let itemStore = env.libraryModel.itemStore
        let loaded: SCNScene? = await Task.detached(priority: .userInitiated) {
            guard let access = try? await itemStore.beginFileAccess(item: currentItem, folderManager: folderManager) else {
                return nil
            }
            defer { access.root.stopAccessingSecurityScopedResource() }
            return MeshRenderer.loadScene(fileURL: access.file)
        }.value
        if item.id == currentItem.id {
            scene = loaded
        }
    }

    // MARK: - Names

    private var nameSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.effectiveName)
                .font(.title2.bold())
                .textSelection(.enabled)
            if item.displayName != nil {
                Text(item.originalName)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Text(item.relPath)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
        }
    }

    // MARK: - Stats

    private var statsSection: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            statRow("Format", ".\(item.ext)")
            statRow("Size", ByteCountFormatter.string(fromByteCount: item.sizeBytes, countStyle: .file))
            if let bx = item.bboxX, let by = item.bboxY, let bz = item.bboxZ {
                statRow("Dimensions", String(format: "%.1f × %.1f × %.1f mm", bx, by, bz))
            }
            if let triangles = item.triangleCount {
                statRow("Triangles", triangles.formatted())
            }
            if let parts = item.partCount, parts > 1 {
                statRow("Parts", parts.formatted())
            }
            if let modified = item.modifiedAt {
                statRow("Modified", modified.formatted(date: .abbreviated, time: .shortened))
            }
            statRow("Indexed", item.indexedAt.formatted(date: .abbreviated, time: .shortened))
            if item.status != .ok {
                statRow("Status", item.status.rawValue.capitalized)
            }
        }
        .font(.callout)
    }

    private func statRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value).textSelection(.enabled)
        }
    }

    // MARK: - AI (FR-5.7/5.9)

    @AppStorage("aiEnabled") private var aiEnabled = false
    @AppStorage("aiBaseURL") private var aiBaseURL = ""
    @AppStorage("aiModel") private var aiModel = ""
    @AppStorage("aiMaxConcurrent") private var aiMaxConcurrent = 2
    @State private var aiRunning = false
    @State private var aiError: String?

    @ViewBuilder
    private func aiSection(itemId: Int64) -> some View {
        if aiEnabled {
            VStack(alignment: .leading, spacing: 8) {
                if let description = item.aiDescription, !description.isEmpty {
                    Text(description)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                // Suggested display name is offered, never applied silently.
                if let suggestion = item.aiSuggestedName, !suggestion.isEmpty,
                   suggestion != item.displayName {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                        Text("Suggested name: “\(suggestion)”")
                            .font(.callout)
                        Button("Use") {
                            Task {
                                try? await env.libraryModel.itemStore.setDisplayName(suggestion, itemId: itemId)
                            }
                        }
                        .controlSize(.small)
                    }
                    .foregroundStyle(.secondary)
                }
                Button {
                    generateAITags(itemId: itemId)
                } label: {
                    Label(aiRunning ? "Generating…" : "Generate AI Tags", systemImage: "sparkles")
                }
                .disabled(aiRunning || item.status != .ok)
                if let aiError {
                    Text(aiError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private func generateAITags(itemId: Int64) {
        aiRunning = true
        aiError = nil
        let client = AIClient(config: AIEndpointConfig(
            baseURL: aiBaseURL, model: aiModel, maxConcurrent: aiMaxConcurrent
        ))
        let service = AITaggingService(database: env.database, cache: env.libraryModel.thumbnailCache)
        Task {
            let errors = await service.tagItems(itemIds: [itemId], client: client)
            aiError = errors[itemId]
            aiRunning = false
        }
    }

    // MARK: - Notes

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Notes").font(.headline)
            TextEditor(text: $notesDraft)
                .font(.body)
                .frame(minHeight: 60, maxHeight: 120)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
                .onChange(of: notesDraft) {
                    saveNotesDebounced()
                }
        }
    }

    @State private var notesSaveTask: Task<Void, Never>?

    private func saveNotesDebounced() {
        notesSaveTask?.cancel()
        let itemId = item.id
        let text = notesDraft
        notesSaveTask = Task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled, let itemId else { return }
            try? await env.libraryModel.itemStore.setNotes(text, itemId: itemId)
        }
    }

    // MARK: - Actions

    private var actionsSection: some View {
        HStack {
            Button {
                revealInFinder()
            } label: {
                Label("Reveal in Finder", systemImage: "magnifyingglass")
            }
            Button {
                openWithDefaultApp()
            } label: {
                Label("Open With Default App", systemImage: "arrow.up.forward.app")
            }
        }
        .disabled(item.status != .ok)
    }

    /// Read-only handoff via NSWorkspace (FR-7.2).
    private func revealInFinder() {
        Task {
            guard let access = try? await env.libraryModel.itemStore.beginFileAccess(
                item: item, folderManager: env.libraryModel.folderManager
            ) else { return }
            NSWorkspace.shared.activateFileViewerSelecting([access.file])
            access.root.stopAccessingSecurityScopedResource()
        }
    }

    private func openWithDefaultApp() {
        Task {
            guard let access = try? await env.libraryModel.itemStore.beginFileAccess(
                item: item, folderManager: env.libraryModel.folderManager
            ) else { return }
            NSWorkspace.shared.open(access.file)
            access.root.stopAccessingSecurityScopedResource()
        }
    }
}
