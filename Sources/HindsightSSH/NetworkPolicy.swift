import Foundation

/// Restricts which hosts may be contacted.
///
/// In debug and test builds the default is `localTestTargetsOnly`, so a mistake
/// while developing cannot reach a real server. Release builds of the app are
/// unrestricted: connecting to real servers is the product.
public struct NetworkPolicy: Sendable, Hashable {
    public enum Mode: Sendable, Hashable {
        case unrestricted
        case localTestTargetsOnly
    }

    public let mode: Mode
    /// Hosts admitted regardless of mode, from `HINDSIGHT_SSH_ALLOW_HOSTS`.
    public let explicitlyAllowedHosts: Set<String>

    public init(mode: Mode, explicitlyAllowedHosts: Set<String> = []) {
        self.mode = mode
        self.explicitlyAllowedHosts = explicitlyAllowedHosts
    }

    public static let unrestricted = NetworkPolicy(mode: .unrestricted)

    public static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> NetworkPolicy {
        let allowed = Set(
            (environment["HINDSIGHT_SSH_ALLOW_HOSTS"] ?? "")
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        )
        // A release build can be pinned to local targets too, which is what a
        // development agent running outside the test suite needs: a catalog
        // full of example servers must not be able to reach for them.
        if environment["HINDSIGHT_SSH_LOCAL_ONLY"] == "1" {
            return NetworkPolicy(mode: .localTestTargetsOnly, explicitlyAllowedHosts: allowed)
        }

        #if DEBUG
        return NetworkPolicy(mode: .localTestTargetsOnly, explicitlyAllowedHosts: allowed)
        #else
        return NetworkPolicy(mode: .unrestricted, explicitlyAllowedHosts: allowed)
        #endif
    }

    public func check(host: String) throws {
        switch mode {
        case .unrestricted:
            return
        case .localTestTargetsOnly:
            guard !explicitlyAllowedHosts.contains(host) else { return }
            guard Self.isLocalTestAddress(host) else {
                throw SSHError.hostNotPermittedInThisBuild(host)
            }
        }
    }

    /// Being a local or private address is necessary but **not** sufficient for
    /// a destructive operation: the target must also carry the test marker file.
    /// See `DestructiveOperationPolicy`.
    public static func isLocalTestAddress(_ host: String) -> Bool {
        let lowered = host.lowercased()
        if lowered == "localhost" || lowered.hasSuffix(".localhost") { return true }
        if lowered.hasSuffix(".orb.local") || lowered.hasSuffix(".internal") { return true }
        if lowered == "::1" || lowered == "[::1]" { return true }

        guard let address = IPv4Address(lowered) else { return false }
        return address.isLoopback || address.isPrivate || address.isCarrierGradeNAT
    }
}

struct IPv4Address: Hashable, Sendable {
    let first: UInt8
    let second: UInt8
    let third: UInt8
    let fourth: UInt8

    init?(_ text: String) {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var values: [UInt8] = []
        for part in parts {
            guard !part.isEmpty, part.count <= 3, part.allSatisfy(\.isNumber),
                  let value = UInt8(part)
            else { return nil }
            values.append(value)
        }
        (first, second, third, fourth) = (values[0], values[1], values[2], values[3])
    }

    var isLoopback: Bool { first == 127 }

    var isPrivate: Bool {
        switch (first, second) {
        case (10, _): true
        case (172, 16...31): true
        case (192, 168): true
        case (169, 254): true
        default: false
        }
    }

    /// OrbStack and some Docker setups hand out addresses in these ranges.
    var isCarrierGradeNAT: Bool {
        (first == 100 && (64...127).contains(second))
            || (first == 198 && (18...19).contains(second))
    }
}
