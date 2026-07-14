import Foundation
import Observation
import PolyShelfCore

/// Dependency container handed to the SwiftUI environment.
@Observable
@MainActor
final class AppEnvironment {
    let database: DatabaseManager
    let libraryModel: LibraryModel

    init(database: DatabaseManager) {
        self.database = database
        self.libraryModel = LibraryModel(database: database)
        libraryModel.activateWatching()
    }

    /// Production environment: database in the sandbox container's Application Support.
    static func live() throws -> AppEnvironment {
        let supportDir = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("PolyShelf", isDirectory: true)
        let dbURL = supportDir.appendingPathComponent("library.sqlite")
        return AppEnvironment(database: try DatabaseManager(databaseURL: dbURL))
    }
}
