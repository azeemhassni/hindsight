import AppKit
import HindsightCore
import HindsightUI
import Quartz

/// Choosing where a server's backups are kept.
@MainActor
enum RepositoryChooser {
    static func run() -> String? {
        let panel = NSOpenPanel()
        panel.title = "Choose where backups are kept"
        panel.message = """
        Hindsight keeps one repository per server inside this folder. It needs \
        room to grow: the first backup is the largest, and history adds to it.
        """
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url.path
    }
}

/// Choosing where to put a file taken out of a backup.
@MainActor
enum FileExport {
    static func chooseDestination(named name: String) -> URL? {
        let panel = NSSavePanel()
        panel.title = "Save a copy from this backup"
        panel.message = """
        This writes a copy onto this Mac. Nothing is sent to the server.
        """
        panel.nameFieldStringValue = name
        panel.canCreateDirectories = true
        panel.prompt = "Save"
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}

/// Looking at one file out of a snapshot without restoring anything.
///
/// The file is extracted to a temporary directory and shown with Quick Look:
/// nothing is written to where it came from, which is the point — checking
/// that a backup holds what you think it holds should not involve a restore.
@MainActor
enum QuickLookPreview {
    static func show(_ file: URL) {
        PreviewSource.shared.urls = [file]
        QLPreviewPanel.shared()?.dataSource = PreviewSource.shared
        QLPreviewPanel.shared()?.makeKeyAndOrderFront(nil)
        QLPreviewPanel.shared()?.reloadData()
    }
}

/// Quick Look asks for its items through a data source rather than taking them
/// directly, so this holds whatever was last extracted.
final class PreviewSource: NSObject, QLPreviewPanelDataSource {
    @MainActor static let shared = PreviewSource()
    var urls: [URL] = []

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        urls[index] as NSURL
    }
}

/// How much disk a repository is using.
enum DirectorySize {
    /// Walked rather than asked of the filesystem, because a repository is a
    /// directory of files with no size of its own. Cached for a short while so
    /// redrawing the window does not re-walk a large repository.
    /// Walked off the main actor: a large repository takes a while, and the
    /// window must keep drawing while it does.
    static func bytesOffMainActor(at path: String) async -> Int64? {
        await Task.detached(priority: .utility) {
            bytes(at: URL(fileURLWithPath: path))
        }.value
    }

    static func bytes(at url: URL) -> Int64? {
        if let cached = cache.value(for: url.path) { return cached }

        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileAllocatedSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var total: Int64 = 0
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(
                forKeys: [.fileAllocatedSizeKey, .isRegularFileKey]
            ), values.isRegularFile == true else { continue }
            total += Int64(values.fileAllocatedSize ?? 0)
        }
        cache.store(total, for: url.path)
        return total
    }

    private static let cache = SizeCache()
}

final class SizeCache: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: (value: Int64, at: Date)] = [:]

    func value(for key: String) -> Int64? {
        lock.withLock {
            guard let entry = entries[key], Date().timeIntervalSince(entry.at) < 60 else { return nil }
            return entry.value
        }
    }

    func store(_ value: Int64, for key: String) {
        lock.withLock { entries[key] = (value, Date()) }
    }
}
