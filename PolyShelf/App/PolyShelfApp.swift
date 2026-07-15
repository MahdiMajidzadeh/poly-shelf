import SwiftUI
import PolyShelfCore

@main
struct PolyShelfApp: App {
    @Environment(\.openWindow) private var openWindow
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
            CommandGroup(replacing: .appInfo) {
                Button("About Poly Shelf") {
                    openWindow(id: "about")
                }
            }
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

        Window("About Poly Shelf", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}
