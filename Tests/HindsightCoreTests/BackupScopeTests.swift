import Foundation
import Testing
@testable import HindsightCore

/// The default profile keeps what cannot be reinstalled and leaves the
/// operating system out, which is why a snapshot holds no kernel and no disk
/// image can be built from one. The other profile exists for people who want
/// that image and will pay for it in gigabytes.
@Suite("What a backup captures")
struct BackupScopeTests {
    @Test("the default captures data and configuration, not the system")
    func defaultLeavesTheSystemOut() {
        let paths = BackupScope.dataAndConfiguration.profile.includePaths
        #expect(paths.contains("/etc"))
        #expect(paths.contains("/srv"))
        #expect(paths.contains("/var/lib/docker/volumes"))

        // The things that make an image possible are exactly what is missing.
        for absent in ["/", "/boot", "/usr", "/lib", "/bin", "/sbin"] {
            #expect(!paths.contains(absent), "\(absent) is not in the default profile")
        }
    }

    @Test("the whole-root profile captures the root, and only skips what it must")
    func rootProfileTakesEverything() {
        let profile = BackupScope.wholeRootFilesystem.profile
        #expect(profile.includePaths == ["/"])

        // Kernel interfaces are not files and cannot be restored.
        for excluded in ["/proc", "/sys", "/dev", "/run"] {
            #expect(profile.excludePatterns.contains(excluded))
        }
        // A container's mounted filesystem belongs to its image, not the host.
        #expect(profile.excludePatterns.contains("/var/lib/docker/overlay2"))
        // But the operating system itself is kept, which is the whole point.
        for kept in ["/usr", "/boot", "/lib", "/var/lib/dpkg"] {
            #expect(
                !profile.excludePatterns.contains(kept),
                "\(kept) must be captured for an image to be buildable"
            )
        }
    }

    @Test("both scopes explain themselves and survive a round trip")
    func scopesAreDescribedAndCodable() throws {
        for scope in BackupScope.allCases {
            #expect(!scope.title.isEmpty)
            #expect(scope.explanation.count > 40, "\(scope) needs a real explanation")
            let decoded = try JSONDecoder().decode(
                BackupScope.self,
                from: try JSONEncoder().encode(scope)
            )
            #expect(decoded == scope)
        }
    }
}
