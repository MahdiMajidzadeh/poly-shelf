import SwiftUI

/// Zero-state shown when no folders have been added yet.
struct OnboardingView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "cube.transparent")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("Welcome to Poly Shelf")
                .font(.largeTitle.bold())
            Text("Add a folder to build a searchable, taggable library of your 3D models.\nYour files are never moved, renamed, or modified.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button {
                env.libraryModel.presentAddFolderPanel()
            } label: {
                Label("Add Folder…", systemImage: "plus")
                    .padding(.horizontal, 8)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
        }
        .frame(minWidth: 480, minHeight: 360)
        .padding(40)
    }
}
