import Foundation
import HindsightProcess

/// Writes a cloud-init NoCloud seed as an ISO.
///
/// `hdiutil makehybrid` is already on every Mac and writes ISO9660 with the
/// volume label the datasource looks for, so this needs nothing vendored.
/// Verified against a seed it produced: the label reads `cidata` and both
/// files are present when it is mounted.
public enum SeedISO {
    /// cloud-init's NoCloud datasource finds a seed by this label and no
    /// other, so it is not a detail that can be tidied.
    public static let volumeName = "cidata"

    public static func write(
        userData: String,
        metaData: String,
        to destination: URL,
        runner: ProcessRunner = ProcessRunner()
    ) async throws -> URL {
        let staging = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hindsight-seed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        try Data(userData.utf8).write(to: staging.appendingPathComponent("user-data"))
        try Data(metaData.utf8).write(to: staging.appendingPathComponent("meta-data"))

        try? FileManager.default.removeItem(at: destination)
        let result = try await runner.run(
            Command(
                path: "/usr/bin/hdiutil",
                arguments: [
                    "makehybrid",
                    "-iso",
                    "-joliet",
                    "-default-volume-name", volumeName,
                    "-o", destination.path,
                    staging.path,
                ]
            ),
            allowedExitCodes: Set((0...255).map(Int32.init)),
            timeout: .seconds(120)
        )
        guard result.exit.terminationStatus == 0 else {
            throw SeedISOError.couldNotWrite(
                result.standardError.isEmpty ? result.standardOutput : result.standardError
            )
        }
        guard FileManager.default.fileExists(atPath: destination.path) else {
            throw SeedISOError.couldNotWrite("hdiutil reported success but wrote nothing.")
        }
        return destination
    }
}

public enum SeedISOError: Error, CustomStringConvertible {
    case couldNotWrite(String)
    case noMetadataSnapshot

    public var description: String {
        switch self {
        case let .couldNotWrite(detail):
            "Could not write the seed image: \(detail)"
        case .noMetadataSnapshot:
            """
            This server has no metadata snapshot yet, and that is where the \
            package list and services are recorded. Back it up once and the \
            image can be built from that.
            """
        }
    }
}
