import Foundation
import HindsightCatalog
import Observation

/// Holds the app's read-only view of the catalog.
///
/// A class rather than a value in `@State`: the closures the window is built
/// with capture the `App` struct as it was when `body` ran, so a value set
/// later is not visible to them. Sharing one object instead keeps the window
/// and those closures looking at the same thing.
@MainActor
@Observable
final class CatalogStore {
    private(set) var reader: CatalogReader?
    private(set) var failure: String?

    func open(at url: URL) {
        do {
            reader = try CatalogReader.open(at: url)
            failure = nil
        } catch {
            reader = nil
            // Worth keeping rather than swallowing: without the catalog the
            // window can still show live state from the agent, but not history.
            failure = "\(error)"
        }
    }
}

/// Repository sizes, measured in the background.
@MainActor
@Observable
final class RepositorySizeStore {
    private var bytesByServer: [String: Int64] = [:]

    func bytes(forServer id: String) -> Int64? {
        bytesByServer[id]
    }

    func record(_ bytes: Int64, forServer id: String) {
        bytesByServer[id] = bytes
    }
}
