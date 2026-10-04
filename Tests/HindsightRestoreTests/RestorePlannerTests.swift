import Foundation
import HindsightCoolify
import HindsightCore
import Testing
@testable import HindsightRestore

@Suite("Restore mode availability")
struct RestorePlannerTests {
    private func coolifyApplication(
        bindMount: Bool = false,
        running: Bool = true,
        proxy: CoolifyProxyFlavour = .traefik,
        volumes: [CoolifyVolume]? = nil
    ) -> RestoreFacts {
        RestoreFacts(
            isCoolifyManaged: true,
            volumes: volumes ?? [
                bindMount
                    ? CoolifyVolume(name: "", mountPath: "/app/data", hostPath: "/srv/app-data")
                    : CoolifyVolume(name: "app-data-abc", mountPath: "/app/data"),
            ],
            proxy: proxy,
            stagingIsOnSameFilesystem: true,
            isDatabase: false,
            hasRunningContainer: running
        )
    }

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

    @Test("zero downtime works for a running Coolify resource on named volumes")
    func zeroDowntimeForCoolifyResource() {
        let availability = RestorePlanner.availability(
            scope: .coolifyResource(uuid: "abc", kind: .application),
            target: .inPlace,
            facts: coolifyApplication()
        )
        let zero = availability.first { $0.mode == .zeroDowntime }
        #expect(zero?.isAvailable == true)
        // The warning is the point: no interruption is not the same as no loss.
        #expect(zero?.dataLossWarning != nil)
        #expect(zero?.dataLossWarning?.contains("not preserved") == true)
    }

    @Test("zero downtime is refused for a bind mount, and says so")
    func zeroDowntimeRefusesBindMounts() {
        let availability = RestorePlanner.availability(
            scope: .coolifyResource(uuid: "abc", kind: .application),
            target: .inPlace,
            facts: coolifyApplication(bindMount: true)
        )
        let zero = try! #require(availability.first { $0.mode == .zeroDowntime })
        #expect(!zero.isAvailable)
        // The explanation has to name the actual obstacle, not be generic.
        #expect(zero.explanation.contains("bind mount"))
        #expect(zero.explanation.contains("/app/data"))
        #expect(zero.dataLossWarning == nil)
    }

    @Test("zero downtime is refused when nothing is running to avoid interrupting")
    func zeroDowntimeRefusesStoppedResource() {
        let availability = RestorePlanner.availability(
            scope: .coolifyResource(uuid: "abc", kind: .application),
            target: .inPlace,
            facts: coolifyApplication(running: false)
        )
        let zero = try! #require(availability.first { $0.mode == .zeroDowntime })
        #expect(!zero.isAvailable)
        #expect(zero.explanation.contains("not running"))
    }

    @Test("zero downtime is refused without a proxy to switch")
    func zeroDowntimeRefusesWithoutProxy() {
        for proxy in [CoolifyProxyFlavour.none, .unknown] {
            let availability = RestorePlanner.availability(
                scope: .coolifyResource(uuid: "abc", kind: .application),
                target: .inPlace,
                facts: coolifyApplication(proxy: proxy)
            )
            let zero = try! #require(availability.first { $0.mode == .zeroDowntime })
            #expect(!zero.isAvailable, "no switchable proxy should rule out zero downtime")
        }
    }

    @Test("zero downtime is refused for a resource with no volumes")
    func zeroDowntimeRefusesWithoutVolumes() {
        let availability = RestorePlanner.availability(
            scope: .coolifyResource(uuid: "abc", kind: .application),
            target: .inPlace,
            facts: coolifyApplication(volumes: [])
        )
        let zero = try! #require(availability.first { $0.mode == .zeroDowntime })
        #expect(!zero.isAvailable)
        #expect(zero.explanation.contains("no persistent volumes"))
    }

    @Test("zero downtime is never offered for a whole server")
    func zeroDowntimeRefusesFullServer() {
        let availability = RestorePlanner.availability(
            scope: .fullServer,
            target: .inPlace,
            facts: coolifyApplication()
        )
        let zero = try! #require(availability.first { $0.mode == .zeroDowntime })
        #expect(!zero.isAvailable)
        #expect(zero.explanation.contains("no second server"))
    }

    @Test("zero downtime is not offered for something Coolify does not manage")
    func zeroDowntimeRefusesUnmanaged() {
        let availability = RestorePlanner.availability(
            scope: .paths(["/srv/app"]),
            target: .inPlace,
            facts: RestoreFacts(isCoolifyManaged: false)
        )
        let zero = try! #require(availability.first { $0.mode == .zeroDowntime })
        #expect(!zero.isAvailable)
        #expect(zero.explanation.contains("Coolify"))
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
            .coolifyResource(uuid: "abc", kind: .database),
            .databaseDump(database: "app"),
        ] {
            for target in [RestoreTarget.inPlace, .alternatePath("/tmp/x"), .anotherServer(serverID: "web-02")] {
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

    @Test("only zero downtime ever carries a data-loss warning")
    func onlyZeroDowntimeWarnsAboutLoss() {
        let availability = RestorePlanner.availability(
            scope: .coolifyResource(uuid: "abc", kind: .application),
            target: .inPlace,
            facts: coolifyApplication()
        )
        for entry in availability where entry.mode != .zeroDowntime {
            #expect(entry.dataLossWarning == nil, "\(entry.mode) must not claim a data-loss caveat")
        }
    }

    @Test("recommends the best mode that is actually possible")
    func recommendsBestAvailable() {
        #expect(
            RestorePlanner.recommendedMode(
                scope: .coolifyResource(uuid: "abc", kind: .application),
                target: .inPlace,
                facts: coolifyApplication()
            ) == .zeroDowntime
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
            RestoreScope.coolifyResource(uuid: "abc", kind: .database)
                .describedForConfirmation == "the database abc"
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
