import SwiftUI
import PolyShelfCore

@main
struct PolyShelfApp: App {
    @State private var environment: AppEnvironment

    init() {
        do {
            _environment = State(initialValue: try AppEnvironment.live())
        } catch {
            fatalError("Failed to open library database: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(environment)
        }
        .windowStyle(.automatic)
        .commands {
            CommandGroup(after: .importExport) {
                Button("Import Metadata…") {
                    environment.libraryModel.importMetadata()
                }
                Button("Export Library Metadata…") {
                    environment.libraryModel.exportMetadata()
                }
            }
        }

        Settings {
            SettingsView()
                .environment(environment)
        }
    }
}
