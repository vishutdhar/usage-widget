import Darwin
import Foundation

/// A moment as the reload scheduler measures it: wall time for display and
/// for comparing across reboots, and a continuous clock that keeps counting
/// through sleep and ignores wall clock changes, for measuring ages within
/// one boot.
public struct SchedulerClock: Codable, Equatable, Sendable {
    public var wall: Date
    /// Nanoseconds from mach_continuous_time. Restarts at boot.
    public var continuous: UInt64
    /// Identifies the boot the continuous reading belongs to, or nil when
    /// that cannot be known.
    public var boot: String?

    public init(wall: Date, continuous: UInt64, boot: String?) {
        self.wall = wall
        self.continuous = continuous
        self.boot = boot
    }

    public static func now() -> SchedulerClock {
        SchedulerClock(wall: Date(), continuous: continuousNanoseconds(), boot: bootSession)
    }

    /// Seconds from `earlier` to this moment: the continuous clock when both
    /// carry the same real boot id, so wall clock changes neither erase nor
    /// invent time; otherwise the wall clock, never below zero. Continuous
    /// readings are never compared without a matching boot id.
    public func seconds(since earlier: SchedulerClock) -> TimeInterval {
        if let boot, let other = earlier.boot, boot == other {
            guard continuous >= earlier.continuous else { return 0 }
            return Double(continuous - earlier.continuous) / 1e9
        }
        return max(0, wall.timeIntervalSince(earlier.wall))
    }

    static func continuousNanoseconds() -> UInt64 {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let ticks = mach_continuous_time()
        return ticks / UInt64(timebase.denom) * UInt64(timebase.numer)
            + ticks % UInt64(timebase.denom) * UInt64(timebase.numer) / UInt64(timebase.denom)
    }

    /// kern.bootsessionuuid names this boot and, unlike kern.boottime, does
    /// not shift when the wall clock is set. Without it there is no boot id
    /// and ages fall back to the wall clock.
    static let bootSession: String? = {
        guard let uuid = sysctlString("kern.bootsessionuuid"), !uuid.isEmpty else { return nil }
        return uuid
    }()

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
