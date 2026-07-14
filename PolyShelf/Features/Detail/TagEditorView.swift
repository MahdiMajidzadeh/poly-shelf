import SwiftUI
import PolyShelfCore

/// Editable tag chips (FR-5.4): auto/AI tags are dimmed with a sparkle glyph,
/// user tags solid; removing an auto tag suppresses it permanently.
struct TagEditorView: View {
    let itemId: Int64
    @Environment(AppEnvironment.self) private var env
    @State private var tags: [ItemTag] = []
    @State private var newTag = ""

    private var tagStore: TagStore { TagStore(database: env.database) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tags").font(.headline)
            FlowLayout(spacing: 6) {
                ForEach(tags) { tag in
                    TagChip(tag: tag) {
                        Task {
                            try? await tagStore.removeTag(tagId: tag.tagId, fromItem: itemId)
                            await reload()
                        }
                    }
                }
            }
            HStack {
                TextField("Add tag…", text: $newTag)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { addTag() }
                Button("Add") { addTag() }
                    .disabled(newTag.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .task(id: itemId) { await reload() }
    }

    private func addTag() {
        let name = newTag
        newTag = ""
        Task {
            try? await tagStore.addUserTag(name, toItem: itemId)
            await reload()
        }
    }

    private func reload() async {
        tags = (try? await tagStore.tags(forItem: itemId)) ?? []
    }
}

struct TagChip: View {
    let tag: ItemTag
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            if tag.provenance != .user {
                Image(systemName: "sparkle")
                    .font(.system(size: 8))
            }
            Text(tag.name)
                .font(.caption)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 7, weight: .bold))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule().fill(tag.provenance == .user
                ? Color.accentColor.opacity(0.25)
                : Color.secondary.opacity(0.12))
        )
        .foregroundStyle(tag.provenance == .user ? .primary : .secondary)
        .help(tag.provenance == .user ? "Your tag" : "Added automatically — removing it suppresses it permanently")
    }
}

/// Minimal wrapping flow layout for tag chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = computeRows(proposal: proposal, subviews: subviews)
        let height = rows.reduce(CGFloat.zero) { $0 + $1.height } + CGFloat(max(0, rows.count - 1)) * spacing
        return CGSize(width: proposal.width ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in computeRows(proposal: proposal, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: .unspecified)
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var height: CGFloat = 0
    }

    private func computeRows(proposal: ProposedViewSize, subviews: Subviews) -> [Row] {
        let maxWidth = proposal.width ?? .infinity
        var rows: [Row] = []
        var current = Row()
        var x: CGFloat = 0
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
                x = 0
            }
            current.indices.append(index)
            current.height = max(current.height, size.height)
            x += size.width + spacing
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
