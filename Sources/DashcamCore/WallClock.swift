import Foundation

/// Source of wall-clock time. Injected everywhere so retention windows and incident
/// windows are deterministic in tests and in the developer simulator.
public protocol WallClock: Sendable {
    func now() -> Date
}

public struct SystemWallClock: WallClock {
    public init() {}
    public func now() -> Date { Date() }
}

/// Deterministic clock for tests and long-duration simulations.
public final class ManualWallClock: WallClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    public init(start: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        current = start
    }

    public func now() -> Date {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    public func advance(by interval: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        current = current.addingTimeInterval(interval)
    }

    public func set(_ date: Date) {
        lock.lock(); defer { lock.unlock() }
        current = date
    }
}
