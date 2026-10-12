import Foundation
import HindsightCore
import Testing
@testable import HindsightRestore

@Suite("Restore mode availability")
struct RestorePlannerTests {
    @Test("standard restore is always possible")
    func standardAlwaysAvailable() {
        for scope in [RestoreScope.fullServer, .paths(["/srv"]), .databaseDump(database: "app")] {
            for target in [RestoreTarget.inPlace, .alternatePath("/tmp/x")] {
                let modes = RestorePlanner.availableModes(
                    scope: scope,
                    target: target,
                    facts: RestoreFacts()
                )
                #expect(modes.contains(.standard), "standard must be available for \(scope) → \(target)")
            }
        }
    }

    /// The brief's rule — never claim zero downtime where it is not true —
    /// is now structural: no mode claims it, so none can claim it falsely.
    @Test("only the two honest modes are on offer")
    func onlyHonestModesExist() {
        #expect(Set(RestoreMode.allCases) == [.minimalDowntime, .standard])
    }

    @Test("a clone restore is offered as a way to look without touching")
    func cloneIsOffered() {
        let modes = RestorePlanner.availableModes(
            scope: .paths(["/srv/app"]),
            target: .clone(suffix: "-restored"),
            facts: RestoreFacts()
        )
        #expect(modes.contains(.standard))
        #expect(RestoreTarget.clone(suffix: "-x").isClone)
        #expect(!RestoreTarget.clone(suffix: "-x").isInPlace)
    }

    @Test("minimal downtime needs staging on the same filesystem")
    func minimalDowntimeNeedsSameFilesystem() {
        var facts = RestoreFacts()
        facts.stagingIsOnSameFilesystem = false
        let availability = RestorePlanner.availability(
            scope: .paths(["/srv/app"]),
            target: .inPlace,
            facts: facts
        )
        let minimal = try! #require(availability.first { $0.mode == .minimalDowntime })
        #expect(!minimal.isAvailable)
        #expect(minimal.explanation.contains("same filesystem"))
    }

    @Test("minimal downtime is offered for an in-place path restore")
    func minimalDowntimeForPaths() {
        let availability = RestorePlanner.availability(
            scope: .paths(["/srv/app"]),
            target: .inPlace,
            facts: RestoreFacts()
        )
        let minimal = try! #require(availability.first { $0.mode == .minimalDowntime })
        #expect(minimal.isAvailable)
        // It must say what the downtime actually covers.
        #expect(minimal.explanation.contains("stop and start"))
    }

    @Test("minimal downtime makes no sense for a database dump")
    func minimalDowntimeRefusesDumps() {
        let availability = RestorePlanner.availability(
            scope: .databaseDump(database: "app"),
            target: .inPlace,
            facts: RestoreFacts(isDatabase: true)
        )
        let minimal = try! #require(availability.first { $0.mode == .minimalDowntime })
        #expect(!minimal.isAvailable)
        #expect(minimal.explanation.contains("loaded by the database"))
    }

    @Test("every mode is explained whether or not it is available")
    func everyModeIsExplained() {
        for scope in [
            RestoreScope.fullServer,
            .paths(["/srv"]),
            .databaseDump(database: "app"),
        ] {
            for target in [
                RestoreTarget.inPlace,
                .alternatePath("/tmp/x"),
                .clone(suffix: "-restored"),
                .anotherServer(serverID: "web-02"),
            ] {
                for availability in RestorePlanner.availability(
                    scope: scope,
                    target: target,
                    facts: RestoreFacts()
                ) {
                    #expect(
                        !availability.explanation.isEmpty,
                        "\(availability.mode) gave no explanation for \(scope) → \(target)"
                    )
                }
            }
        }
    }

    @Test("no available mode carries a data-loss caveat, because none loses data")
    func noAvailableModeLosesData() {
        let availability = RestorePlanner.availability(
            scope: .paths(["/srv/app"]),
            target: .inPlace,
            facts: RestoreFacts()
        )
        for entry in availability where entry.isAvailable {
            #expect(entry.dataLossWarning == nil, "\(entry.mode) must not claim a data-loss caveat")
        }
    }

    @Test("recommends the best mode that is actually possible")
    func recommendsBestAvailable() {
        #expect(
            RestorePlanner.recommendedMode(
                scope: .paths(["/srv/app"]),
                target: .inPlace,
                facts: RestoreFacts()
            ) == .minimalDowntime
        )
        #expect(
            RestorePlanner.recommendedMode(
                scope: .paths(["/srv"]),
                target: .inPlace,
                facts: RestoreFacts()
            ) == .minimalDowntime
        )
        #expect(
            RestorePlanner.recommendedMode(
                scope: .fullServer,
                target: .alternatePath("/tmp/x"),
                facts: RestoreFacts()
            ) == .standard
        )
    }

    @Test("describes the scope in words for the confirmation step")
    func describesScope() {
        #expect(RestoreScope.fullServer.describedForConfirmation == "the whole server")
        #expect(RestoreScope.paths(["/srv/app"]).describedForConfirmation == "/srv/app")
        #expect(RestoreScope.paths(["/a", "/b"]).describedForConfirmation == "2 paths")
        #expect(
            RestoreScope.databaseDump(database: "shop").describedForConfirmation == "the database shop"
        )
    }

    @Test("maps restic's diff modifiers onto what a person needs to see")
    func mapsDiffModifiers() {
        #expect(RestorePreview.kind(forModifier: "+") == .added)
        #expect(RestorePreview.kind(forModifier: "-") == .removed)
        #expect(RestorePreview.kind(forModifier: "M") == .modified)
        #expect(RestorePreview.kind(forModifier: "U") == .metadata)
        #expect(RestorePreview.kind(forModifier: "T") == .metadata)
    }
}
