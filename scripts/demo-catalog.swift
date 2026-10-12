// Builds a catalog with plausible history, so the interface can be looked at
// without connecting to a real server. Writes only to the path it is given.
import Foundation
import HindsightCatalog
import HindsightCore

let destination = URL(fileURLWithPath: CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : NSTemporaryDirectory() + "hindsight-demo/catalog.sqlite")

try? FileManager.default.removeItem(at: destination)
let catalog = try Catalog.open(at: destination)

struct Seed {
    let id: String
    let name: String
    let host: String
    let lastBackupHoursAgo: Double
    let checkPassed: Bool
    let snapshotCount: Int
}

let seeds = [
    Seed(id: "web-01", name: "Web 01", host: "198.51.100.10",
         lastBackupHoursAgo: 0.4, checkPassed: true, snapshotCount: 42),
    Seed(id: "db-01", name: "Database 01", host: "198.51.100.11",
         lastBackupHoursAgo: 3.2, checkPassed: true, snapshotCount: 58),
    Seed(id: "builder", name: "Build server", host: "198.51.100.12",
         lastBackupHoursAgo: 71, checkPassed: true, snapshotCount: 12),
    Seed(id: "legacy", name: "Legacy box", host: "198.51.100.13",
         lastBackupHoursAgo: 9, checkPassed: false, snapshotCount: 30),
]

for seed in seeds {
    let id = try ServerID(validating: seed.id)
    try catalog.save(
        try Server(
            id: id,
            name: seed.name,
            endpoint: try SSHEndpoint(host: seed.host, port: 22, user: "root"),
            authentication: .managedKey,
            privilege: .root,
            platform: Platform(
                distributionID: "ubuntu", versionID: "24.04",
                prettyName: "Ubuntu 24.04.1 LTS", kernelRelease: "6.8.0-41-generic",
                architecture: .aarch64
            )
        )
    )

    let repositoryID = "repo-\(seed.id)"
    try catalog.save(
        RepositoryRecord(
            id: repositoryID,
            serverId: seed.id,
            path: "/Volumes/Backups/Hindsight/repos/\(seed.id)"
        )
    )

    try catalog.save(
        ScheduleRecord(
            id: "sched-\(seed.id)",
            serverId: seed.id,
            schedule: try Schedule(cadence: .everyHours(6), onlyOnACPower: true)
        )
    )

    // History that thins out with age, with the occasional large day, so the
    // timeline has something real to show.
    var snapshots: [Snapshot] = []
    for index in 0..<seed.snapshotCount {
        let hoursAgo = seed.lastBackupHoursAgo + Double(index) * 6
        let added: Int64 = index == 0
            ? 180_000_000
            : Int64(2_000_000 + (index * 7919 % 40) * 1_500_000)
        snapshots.append(
            Snapshot(
                id: SnapshotID(unchecked: String(format: "%064x", index &* 7919 &+ seed.id.hashValue & 0xFFFF)),
                time: Date().addingTimeInterval(-hoursAgo * 3600),
                hostname: seed.id,
                paths: ["/etc", "/home", "/srv", "/var/lib/docker/volumes"],
                tags: ["hindsight", "profile:full"],
                kind: .filesystem,
                sizeBytes: 9_400_000_000,
                dataAddedBytes: added
            )
        )
    }
    try catalog.record(snapshots, inRepository: repositoryID)

    let jobID = JobID.generate()
    var job = JobRecord(id: jobID, serverId: id, kind: .backup)
    job.state = .succeeded
    job.startedAt = Date().addingTimeInterval(-seed.lastBackupHoursAgo * 3600 - 240)
    job.finishedAt = Date().addingTimeInterval(-seed.lastBackupHoursAgo * 3600)
    job.bytesProcessed = 9_400_000_000
    job.bytesAdded = snapshots.first?.dataAddedBytes
    try catalog.save(job)

    var check = IntegrityCheckRecord(
        repositoryId: repositoryID,
        kind: .readDataSubset,
        subsetIndex: 2,
        subsetDivisor: 4,
        startedAt: Date().addingTimeInterval(-26 * 3600)
    )
    check.outcome = seed.checkPassed ? .passed : .failed
    check.errorText = seed.checkPassed ? nil : "pack 4f1c9a is damaged"
    try catalog.save(check)
}

print(destination.path)
