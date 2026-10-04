import Foundation
import HindsightProtocol
import Testing
@testable import HindsightUI

@Suite("Formatting")
struct FormattingTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("describes ages the way a person would say them")
    func formatsAges() {
        #expect(Format.age(of: nil) == "never")
        #expect(Format.age(of: now.addingTimeInterval(-30), now: now) == "just now")
        #expect(Format.age(of: now.addingTimeInterval(-600), now: now) == "10m ago")
        #expect(Format.age(of: now.addingTimeInterval(-7200), now: now) == "2h ago")
        #expect(Format.age(of: now.addingTimeInterval(-86400 * 3), now: now) == "3d ago")
        // Beyond a week a date is more useful than a count of days.
        #expect(Format.age(of: now.addingTimeInterval(-86400 * 30), now: now).contains("20"))
    }

    @Test("does not pretend a clock skew is a sensible age")
    func handlesFutureDates() {
        #expect(Format.age(of: now.addingTimeInterval(3600), now: now) == "in the future")
    }

    @Test("describes when the next backup is due")
    func formatsTimeUntil() {
        #expect(Format.timeUntil(nil) == "not scheduled")
        #expect(Format.timeUntil(now.addingTimeInterval(-10), now: now) == "due now")
        #expect(Format.timeUntil(now.addingTimeInterval(30), now: now) == "in under a minute")
        #expect(Format.timeUntil(now.addingTimeInterval(1800), now: now) == "in 30m")
        #expect(Format.timeUntil(now.addingTimeInterval(7200), now: now) == "in 2h")
        #expect(Format.timeUntil(now.addingTimeInterval(86400 * 2), now: now) == "in 2d")
    }

    @Test("formats sizes and leaves unknowns visibly unknown")
    func formatsBytes() {
        #expect(Format.bytes(nil) == "—")
        #expect(Format.bytes(0).contains("0"))
        #expect(Format.bytes(1_500_000).contains("MB"))
        #expect(Format.bytes(2_000_000_000).contains("GB"))
    }

    @Test("formats durations across the range a backup can take")
    func formatsDurations() {
        #expect(Format.duration(nil) == "—")
        #expect(Format.duration(.milliseconds(250)) == "250 ms")
        #expect(Format.duration(.seconds(5)) == "5.0 s")
        #expect(Format.duration(.seconds(125)) == "2m 5s")
        #expect(Format.duration(.seconds(3700)) == "1h 1m")
    }

    @Test("states savings as a ratio, which is easier to believe than a percentage")
    func formatsSavings() {
        #expect(Format.savings(stored: 1000, processed: 3400) == "3.4× smaller")
        // Nothing to claim when there is no saving, or no data.
        #expect(Format.savings(stored: 0, processed: 100) == "—")
        #expect(Format.savings(stored: 100, processed: 50) == "—")
    }

    @Test("formats transfer rates and refuses to extrapolate from nothing")
    func formatsTransferRate() {
        #expect(Format.transferRate(bytes: 10_000_000, over: .seconds(10)).contains("/s"))
        #expect(Format.transferRate(bytes: nil, over: .seconds(10)) == "—")
        // A rate from a 50 ms sample would be a guess dressed up as a fact.
        #expect(Format.transferRate(bytes: 1000, over: .milliseconds(50)) == "—")
    }

    @Test("formats the estimate restic gives, and nothing when it gives none")
    func formatsEstimate() {
        #expect(Format.estimatedTimeRemaining(nil) == "—")
        #expect(Format.estimatedTimeRemaining(0) == "—")
        #expect(Format.estimatedTimeRemaining(45) == "45s left")
        #expect(Format.estimatedTimeRemaining(300) == "5m left")
        #expect(Format.estimatedTimeRemaining(7200) == "2h 0m left")
    }

    @Test("every health state has a label, a symbol, and something for VoiceOver")
    func describesHealth() {
        for health in [
            ServerStatus.Health.healthy, .stale, .failing, .unknown,
        ] {
            #expect(!health.label.isEmpty)
            #expect(!health.symbolName.isEmpty)
            // The spoken description must stand alone, because a colour and a
            // dot say nothing to a screen reader.
            #expect(health.accessibilityDescription.count > health.label.count)
        }
        #expect(ServerStatus.Health.failing.accessibilityDescription.contains("integrity"))
        #expect(ServerStatus.Health.unknown.accessibilityDescription.contains("not been backed up"))
    }

    @Test("sorts what needs attention to the top")
    func sortsBySeverity() {
        let sorted = [
            ServerStatus.Health.healthy, .unknown, .failing, .stale,
        ].sorted { $0.severity < $1.severity }
        #expect(sorted == [.failing, .stale, .unknown, .healthy])
    }
}

@Suite("Snapshot tree")
struct SnapshotTreeTests {
    private let listing: [(path: String, isDirectory: Bool, size: Int64?, modified: Date?, permissions: String?)] = [
        ("/srv", true, nil, nil, "drwxr-xr-x"),
        ("/srv/app", true, nil, nil, "drwxr-xr-x"),
        ("/srv/app/config.yml", false, 512, nil, "-rw-r--r--"),
        ("/srv/app/logs", true, nil, nil, "drwxr-xr-x"),
        ("/srv/app/logs/today.log", false, 2048, nil, "-rw-r--r--"),
        ("/srv/readme.txt", false, 64, nil, "-rw-r--r--"),
    ]

    @Test("lists one level at a time, collapsing what is deeper")
    func listsOneLevel() {
        let children = SnapshotTreeBuilder.children(of: "/srv", from: listing)
        #expect(children.map(\.name) == ["app", "readme.txt"])
        #expect(children[0].isDirectory)
        #expect(!children[1].isDirectory)
        #expect(children[1].sizeBytes == 64)
    }

    @Test("puts directories before files, then sorts naturally")
    func ordersSensibly() {
        let children = SnapshotTreeBuilder.children(of: "/srv/app", from: listing)
        #expect(children.map(\.name) == ["logs", "config.yml"])
    }

    @Test("an unopened directory is not the same as an empty one")
    func distinguishesUnloadedFromEmpty() {
        let unloaded = SnapshotTreeNode(path: "/srv", name: "srv", isDirectory: true)
        #expect(!unloaded.isLoaded)

        let empty = SnapshotTreeNode(path: "/srv", name: "srv", isDirectory: true, children: [])
        #expect(empty.isLoaded)
        #expect(empty.children?.isEmpty == true)
    }

    @Test("knows which files are worth previewing")
    func knowsWhatToPreview() {
        func node(_ name: String, isDirectory: Bool = false) -> SnapshotTreeNode {
            SnapshotTreeNode(path: "/x/" + name, name: name, isDirectory: isDirectory)
        }
        #expect(node("config.yml").isPreviewable)
        #expect(node("app.log").isPreviewable)
        #expect(node("screenshot.png").isPreviewable)
        // Server configuration often has no extension at all.
        #expect(node("hosts").isPreviewable)
        #expect(!node("data.sqlite").isPreviewable)
        #expect(!node("blob.bin").isPreviewable)
        #expect(!node("srv", isDirectory: true).isPreviewable)
    }

    @Test("searches on the file name and caps the results")
    func searches() {
        let paths = listing.map(\.path)
        #expect(
            SnapshotTreeBuilder.search("log", in: paths)
                == ["/srv/app/logs", "/srv/app/logs/today.log"]
        )
        #expect(SnapshotTreeBuilder.search("CONFIG", in: paths) == ["/srv/app/config.yml"])
        #expect(SnapshotTreeBuilder.search("  ", in: paths).isEmpty)
        #expect(SnapshotTreeBuilder.search("x", in: Array(repeating: "/a/x", count: 2000), limit: 10).count == 10)
    }

    @Test("every kind of change has a label and a symbol")
    func describesChanges() {
        for change in [
            SnapshotDiffEntry.Change.added, .removed, .modified, .metadata,
        ] {
            #expect(!change.label.isEmpty)
            #expect(!change.symbolName.isEmpty)
        }
        #expect(SnapshotDiffEntry.Change.metadata.label.contains("ownership"))
    }
}
