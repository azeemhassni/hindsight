import Foundation
import HindsightCore
import HindsightProcess
import HindsightRestic
import HindsightTestSupport
import Testing
@testable import HindsightSchedule

/// The retention engine exists to preview deletions. A preview that disagrees
/// with what restic actually does is worse than no preview, so this suite
/// compares the two on a real repository, snapshot for snapshot.
@Suite("Retention agrees with restic", .timeLimit(.minutes(10)), .serialized)
struct RetentionAgreementTests {
    static var resticAvailable: Bool {
        (try? BinaryStore(directory: TestEnvironment.vendorBinDirectory())
            .verifiedURL(for: try PinnedBinaries.hostRestic)) != nil
    }

    /// Two years of history shaped like a real server's: dense recently,
    /// thinning out with age, with several snapshots on some days.
    static func syntheticTimes(now: Date) -> [Date] {
        var times: [Date] = []
        let calendar = Calendar(identifier: .gregorian)

        for hour in stride(from: 1, through: 36, by: 3) {
            times.append(calendar.date(byAdding: .hour, value: -hour, to: now)!)
        }
        for day in 2...20 {
            times.append(calendar.date(byAdding: .day, value: -day, to: now)!)
            if day % 3 == 0 {
                times.append(calendar.date(byAdding: .hour, value: -(day * 24 + 7), to: now)!)
            }
        }
        for week in 4...16 {
            times.append(calendar.date(byAdding: .day, value: -week * 7, to: now)!)
        }
        for month in 5...24 {
            times.append(calendar.date(byAdding: .day, value: -month * 30, to: now)!)
        }
        return times.sorted()
    }

    struct Corpus {
        let client: ResticClient
        let snapshots: [Snapshot]
    }

    /// Built once for the whole suite.
    ///
    /// Each snapshot is a separate restic invocation, so a corpus large enough
    /// to be meaningful costs about a minute. Building it per test tripled the
    /// suite's runtime for no extra coverage.
    private actor CorpusCache {
        static let shared = CorpusCache()
        private var corpus: Corpus?

        func get() async throws -> Corpus {
            if let corpus { return corpus }
            let built = try await buildCorpus()
            corpus = built
            return built
        }
    }

    static func corpus() async throws -> Corpus {
        try await CorpusCache.shared.get()
    }

    static func buildCorpus() async throws -> Corpus {
        let root = try TestEnvironment.temporaryRepositoryRoot()
        let repository = root.appendingPathComponent("retention")
        let password = Secret(label: "repo", value: "retention-test")
        let executable = try BinaryStore(directory: TestEnvironment.vendorBinDirectory())
            .verifiedURL(for: try PinnedBinaries.hostRestic)

        let client = ResticClient(
            executable: executable,
            location: .local(repository),
            password: password
        )
        _ = try await client.initializeIfNeeded()

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.timeZone = .current

        let runner = ProcessRunner()
        for (index, time) in syntheticTimes(now: Date()).enumerated() {
            let command = Command(
                path: executable.path,
                arguments: [
                    "backup", "--stdin", "--stdin-filename", "payload.txt",
                    "--time", formatter.string(from: time),
                    "--tag", "hindsight",
                ],
                environment: Environment(
                    values: ["RESTIC_REPOSITORY": repository.path],
                    secretValues: ["RESTIC_PASSWORD": password]
                ),
                standardInput: .data(Data("snapshot-\(index)\n".utf8))
            )
            try await runner.run(command)
        }

        let listed = try await client.snapshots()
        return Corpus(client: client, snapshots: listed.map { $0.toSnapshot() })
    }

    static let policies: [(name: String, policy: RetentionPolicy)] = {
        func make(_ within: Int, _ daily: Int, _ weekly: Int, _ monthly: Int, _ yearly: Int) -> RetentionPolicy {
            try! RetentionPolicy(
                scope: .filesystem,
                keepWithinHours: within,
                keepDaily: daily,
                keepWeekly: weekly,
                keepMonthly: monthly,
                keepYearly: yearly
            )
        }
        return [
            ("documented default", .filesystemDefault),
            ("dumps default", .databaseDumpsDefault),
            ("daily only", make(0, 7, 0, 0, 0)),
            ("weekly only", make(0, 0, 4, 0, 0)),
            ("monthly only", make(0, 0, 0, 12, 0)),
            ("yearly only", make(0, 0, 0, 0, 2)),
            ("within only", make(72, 0, 0, 0, 0)),
            ("everything, generous", make(168, 30, 12, 24, 5)),
            ("everything, mean", make(1, 1, 1, 1, 1)),
            ("long window", make(24 * 40, 3, 2, 2, 1)),
        ]
    }()

    @Test("predicts exactly the snapshots restic would forget", .enabled(if: resticAvailable))
    func agreesWithResticOnEveryPolicy() async throws {
        let corpus = try await Self.corpus()
        #expect(corpus.snapshots.count > 50, "the corpus is too small to be meaningful")

        for (name, policy) in Self.policies {
            let predicted = RetentionEngine.applyPerGroup(policy, to: corpus.snapshots)
            let groups = try await corpus.client.forget(policy: policy, dryRun: true)

            let actualKeep = Set(groups.flatMap { ($0.keep ?? []).map(\.id) })
            let actualRemove = Set(groups.flatMap { ($0.remove ?? []).map(\.id) })

            var resticReasons: [String: [String]] = [:]
            for group in groups {
                for reason in group.reasons ?? [] {
                    resticReasons[reason.snapshot.id] = reason.matches
                }
            }
            let describe: (Set<String>) -> String = { ids in
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd HH:mm"
                let byID = Dictionary(uniqueKeysWithValues: corpus.snapshots.map { ($0.id.value, $0) })
                return ids.sorted()
                    .compactMap { byID[$0] }
                    .sorted { $0.time > $1.time }
                    .prefix(8)
                    .map {
                        "\(formatter.string(from: $0.time)) ours=\(predicted.reasons[$0.id.value] ?? [])"
                            + " restic=\(resticReasons[$0.id.value] ?? [])"
                    }
                    .joined(separator: ", ")
            }
            #expect(
                predicted.keepIDs == actualKeep,
                """
                \(name): kept set differs.
                  only ours:   \(describe(predicted.keepIDs.subtracting(actualKeep)))
                  only restic: \(describe(actualKeep.subtracting(predicted.keepIDs)))
                """
            )
            #expect(predicted.removeIDs == actualRemove, "\(name): removed set differs")
            #expect(actualKeep.count + actualRemove.count == corpus.snapshots.count)
        }
    }

    @Test("explains its decisions and scopes dumps separately", .enabled(if: resticAvailable))
    func explainsItsDecisions() async throws {
        let corpus = try await Self.corpus()
        let decision = RetentionEngine.applyPerGroup(.filesystemDefault, to: corpus.snapshots)

        for snapshot in decision.keep {
            let reasons = decision.reasons[snapshot.id.value] ?? []
            #expect(!reasons.isEmpty, "\(snapshot.id.short) was kept with no reason given")
        }
        for snapshot in decision.remove {
            #expect(decision.reasons[snapshot.id.value] == nil)
        }

        // The same history under both default policies: the dump policy keeps
        // strictly more, which is the point of giving dumps their own scope.
        let dumps = RetentionEngine.applyPerGroup(.databaseDumpsDefault, to: corpus.snapshots)
        #expect(dumps.keep.count > decision.keep.count)
        #expect(decision.keepIDs.isSubset(of: dumps.keepIDs))
    }
}
