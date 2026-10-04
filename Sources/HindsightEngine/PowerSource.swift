import Foundation
import IOKit.ps

/// Whether the Mac is on mains power.
///
/// Behind a protocol so the scheduler's behaviour on battery can be tested
/// without a battery.
public protocol PowerSourceReading: Sendable {
    func isOnACPower() -> Bool
}

public struct SystemPowerSource: PowerSourceReading {
    public init() {}

    public func isOnACPower() -> Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return true }
        guard let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else {
            return true
        }
        // A desktop reports no battery sources at all, which is mains power.
        guard !sources.isEmpty else { return true }

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(snapshot, source)?
                .takeUnretainedValue() as? [String: Any] else { continue }
            if let state = description[kIOPSPowerSourceStateKey] as? String,
               state == kIOPSACPowerValue {
                return true
            }
        }
        return false
    }
}

/// Always reports mains power. Used where power is irrelevant.
public struct AlwaysOnACPower: PowerSourceReading {
    public init() {}
    public func isOnACPower() -> Bool { true }
}
