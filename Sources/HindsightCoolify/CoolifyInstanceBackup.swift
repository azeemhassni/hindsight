import Foundation
import HindsightCore

/// What to capture to be able to rebuild a Coolify instance.
///
/// Derived from a live v4.3.23 install rather than from documentation; see
/// `docs/COOLIFY.md` for how each path was established.
public enum CoolifyInstancePlan {
    /// The environment file holding `APP_KEY`.
    ///
    /// Without it, every credential and private key in Coolify's database is
    /// undecryptable, so a restored instance is useless. It is the single most
    /// important file on a Coolify server.
    public static let environmentFileName = ".env"
    public static let sourceDirectory = "/data/coolify/source"
    public static var environmentFile: String { "\(sourceDirectory)/\(environmentFileName)" }

    /// Let's Encrypt's account key and every issued certificate. Losing it
    /// means re-issuing, with rate limits waiting.
    public static let acmeFile = "/data/coolify/proxy/acme.json"

    public static let includePaths = [
        "/data/coolify/source",
        "/data/coolify/ssh",
        "/data/coolify/proxy",
        "/data/coolify/ssl",
        "/data/coolify/applications",
        "/data/coolify/services",
        "/data/coolify/databases",
    ]

    /// Monitoring data is regenerated and written constantly, so including it
    /// would add churn to every backup for no benefit. Logs are similar.
    public static let excludePatterns = [
        "/data/coolify/sentinel/metrics.sqlite",
        "/data/coolify/sentinel/metrics.sqlite-wal",
        "/data/coolify/sentinel/metrics.sqlite-shm",
        "/data/coolify/source/installation-*.log",
        "/data/coolify/source/upgrade-*.log",
        "/data/coolify/ssh/mux",
    ]

    /// Files whose absence from a snapshot means the backup is not usable for a
    /// restore, and so should fail the job rather than be reported as good.
    public static var requiredFiles: [String] { [environmentFile] }

    public static let databaseContainer = "coolify-db"
    public static let databaseUser = "coolify"
    public static let databaseName = "coolify"

    /// `PGUSER` is set inside the container, so no password has to leave it.
    public static let databaseDumpCommand = """
    docker exec coolify-db pg_dump --format=custom --no-owner --no-privileges \
      --username=coolify --dbname=coolify
    """

    public static func profile() throws -> BackupProfile {
        try BackupProfile(
            includePaths: includePaths,
            excludePatterns: excludePatterns,
            oneFileSystem: false
        )
    }

    public static var tags: [SnapshotTag] {
        [.hindsight, .profile("coolify-instance")]
    }
}

/// Which proxy a server runs, since it decides how routing can be switched.
public enum CoolifyProxyFlavour: String, Sendable, Hashable, Codable {
    case traefik
    case caddy
    case none
    case unknown

    /// Read from the image of the `coolify-proxy` container. A default v4
    /// install runs Traefik, but Caddy is selectable per server, so this is
    /// detected rather than assumed.
    public init(proxyImage: String?) {
        guard let image = proxyImage?.lowercased(), !image.isEmpty else {
            self = .none
            return
        }
        if image.contains("traefik") {
            self = .traefik
        } else if image.contains("caddy") {
            self = .caddy
        } else {
            self = .unknown
        }
    }

    public var dynamicConfigurationPath: String? {
        switch self {
        case .traefik, .caddy: "/data/coolify/proxy/dynamic"
        case .none, .unknown: nil
        }
    }
}
