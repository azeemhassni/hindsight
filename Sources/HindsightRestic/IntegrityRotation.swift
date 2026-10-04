import Foundation

/// Schedules `check --read-data-subset` so the whole repository is read and
/// verified over a window, without reading all of it every time.
///
/// A structural check is cheap and catches a broken index; only reading the
/// pack data catches bit rot, and that is too expensive to do nightly on a
/// large repository. The rotation makes the expensive check routine.
public struct IntegrityRotation: Sendable, Hashable {
    public var divisor: Int
    public var index: Int

    public init(divisor: Int = 4, index: Int = 0) {
        self.divisor = max(1, divisor)
        self.index = index
    }

    /// restic numbers subsets from 1.
    public var subsetArgument: String { "\((index % divisor) + 1)/\(divisor)" }

    public func advanced() -> IntegrityRotation {
        IntegrityRotation(divisor: divisor, index: (index + 1) % divisor)
    }

    /// True when the next run completes a full pass over the repository.
    public var completesFullPassAfterThisRun: Bool { index == divisor - 1 }

    public func describeProgress() -> String {
        "part \(index + 1) of \(divisor)"
    }
}
