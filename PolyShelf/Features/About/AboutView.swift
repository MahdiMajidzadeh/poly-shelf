import SwiftUI

/// Custom About window (replaces the standard AppKit about panel).
/// Version reads from the bundle so it tracks the tag-injected release
/// version (see scripts/build-app.sh); falls back to 0.1.0 for dev builds.
struct AboutView: View {
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)

            VStack(spacing: 4) {
                Text("Poly Shelf")
                    .font(.title.weight(.semibold))
                Text("Your 3D model library, organized in place.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Text("Version \(version)")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Divider()
                .frame(width: 180)

            VStack(spacing: 2) {
                Text("Created by Mahdi Majidzadeh")
                    .font(.footnote)
                Text("Indexes, tags, and searches your models without ever moving a file.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(28)
        .frame(width: 360, height: 320)
    }
}
