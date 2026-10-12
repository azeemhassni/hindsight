import Foundation
import HindsightCore
import Testing
@testable import HindsightUI

/// Records what the browser asked the agent for, so a test can prove the tree
/// is read as folders are opened and never read twice.
@MainActor
final class RecordingLoader {
    var requested: [String] = []
    var tree: [String: [SnapshotTreeNode]] = [:]

    func load(_ path: String) async -> [SnapshotTreeNode] {
        requested.append(path)
        return tree[path] ?? []
    }

    static func directory(_ path: String) -> SnapshotTreeNode {
        SnapshotTreeNode(path: path, name: (path as NSString).lastPathComponent, isDirectory: true)
    }

    static func file(_ path: String, size: Int64 = 10) -> SnapshotTreeNode {
        SnapshotTreeNode(
            path: path,
            name: (path as NSString).lastPathComponent,
            isDirectory: false,
            sizeBytes: size
        )
    }
}

@MainActor
@Suite("Browsing a snapshot")
struct SnapshotBrowserModelTests {
    private func loaded() -> (SnapshotBrowserModel, RecordingLoader) {
        let loader = RecordingLoader()
        loader.tree = [
            "/": [RecordingLoader.directory("/srv"), RecordingLoader.file("/hosts")],
            "/srv": [RecordingLoader.directory("/srv/app"), RecordingLoader.file("/srv/note.txt")],
            "/srv/app": [RecordingLoader.file("/srv/app/main.js", size: 2048)],
        ]
        let model = SnapshotBrowserModel(load: { await loader.load($0) })
        return (model, loader)
    }

    @Test("shows the root and asks for nothing else")
    func startsAtTheRoot() async {
        let (model, loader) = loaded()
        await model.start()

        #expect(loader.requested == ["/"])
        #expect(model.rows.map(\.node.name) == ["srv", "hosts"])
        #expect(model.rows.allSatisfy { $0.depth == 0 })
        #expect(!model.isLoadingRoot)
    }

    @Test("opening a folder reads it, and reads it only once")
    func readsAFolderOnce() async {
        let (model, loader) = loaded()
        await model.start()

        await model.toggle("/srv")
        #expect(loader.requested == ["/", "/srv"])
        #expect(model.rows.map(\.node.name) == ["srv", "app", "note.txt", "hosts"])
        #expect(model.rows.first { $0.node.name == "app" }?.depth == 1)

        // Closed and opened again: the listing is already held, so nothing is
        // read a second time.
        await model.toggle("/srv")
        #expect(model.rows.map(\.node.name) == ["srv", "hosts"])
        await model.toggle("/srv")
        #expect(loader.requested == ["/", "/srv"])
        #expect(model.rows.count == 4)
    }

    @Test("a folder nobody has opened is not claimed to be empty")
    func unopenedFolderIsNotEmpty() async {
        let (model, _) = loaded()
        await model.start()

        let folder = try? #require(model.rows.first { $0.node.name == "srv" })
        #expect(folder?.isEmptyDirectory == false)

        await model.toggle("/srv")
        await model.toggle("/srv/app")
        // Now it has been read and genuinely holds nothing.
        let empty = SnapshotBrowserModel(load: { _ in [] })
        await empty.start()
        #expect(empty.rows.isEmpty)
    }

    @Test("revealing a path opens every folder on the way to it")
    func revealsADeepPath() async {
        let (model, loader) = loaded()
        await model.start()

        await model.reveal("/srv/app/main.js")
        #expect(loader.requested == ["/", "/srv", "/srv/app"])
        #expect(model.rows.map(\.node.name) == ["srv", "app", "main.js", "note.txt", "hosts"])
        #expect(model.selection == "/srv/app/main.js")
        #expect(model.selectedNode?.sizeBytes == 2048)
    }

    @Test("a search covers the whole snapshot, not only what is open")
    func searchesTheWholeSnapshot() async {
        let loader = RecordingLoader()
        loader.tree = ["/": [RecordingLoader.directory("/srv")]]
        var searched: [String] = []
        let model = SnapshotBrowserModel(
            load: { await loader.load($0) },
            find: { term in
                searched.append(term)
                return SnapshotSearchOutcome(
                    nodes: [RecordingLoader.file("/srv/app/deep/buried.conf")],
                    truncated: true
                )
            }
        )
        await model.start()
        await model.search("buried")

        // The match is somewhere nobody opened, which the old in-memory filter
        // could never have found.
        #expect(searched == ["buried"])
        #expect(model.matches.map(\.name) == ["buried.conf"])
        #expect(model.mode == .results(term: "buried", truncated: true))

        model.clearSearch()
        #expect(model.mode == .tree)
        #expect(model.matches.isEmpty)
    }

    @Test("an empty search goes back to the tree without asking the agent")
    func emptySearchIsNotASearch() async {
        let loader = RecordingLoader()
        loader.tree = ["/": [RecordingLoader.file("/hosts")]]
        var calls = 0
        let model = SnapshotBrowserModel(
            load: { await loader.load($0) },
            find: { _ in
                calls += 1
                return SnapshotSearchOutcome(nodes: [])
            }
        )
        await model.start()
        await model.search("   ")
        #expect(calls == 0)
        #expect(model.mode == .tree)
    }
}
