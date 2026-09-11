import Foundation

/// The cumulative "Freed all-time" figure in the footer, and the session count (FR-6).
///
/// This is the only state the app keeps between launches besides the delete mode — scans
/// themselves are stateless by design (doc 00).
public struct FreedStats: Sendable {
    // UserDefaults is documented as thread-safe but is not marked Sendable, so the annotation
    // states what the framework guarantees rather than opting out of a real check.
    nonisolated(unsafe) private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var totalBytesFreed: Int64 {
        Int64(defaults.integer(forKey: Settings.Key.totalBytesFreed))
    }

    /// Number of cleaning sessions — a session being one confirmed delete run that freed
    /// something, not one launch.
    public var sessions: Int {
        defaults.integer(forKey: Settings.Key.sessions)
    }

    public var formattedTotal: String {
        ByteFormatting.string(totalBytesFreed)
    }

    /// Records one completed delete run. A run that freed nothing does not count as a session.
    public func add(_ bytes: Int64) {
        guard bytes > 0 else { return }
        defaults.set(Int(totalBytesFreed + bytes), forKey: Settings.Key.totalBytesFreed)
        defaults.set(sessions + 1, forKey: Settings.Key.sessions)
    }

    public func reset() {
        defaults.removeObject(forKey: Settings.Key.totalBytesFreed)
        defaults.removeObject(forKey: Settings.Key.sessions)
    }
}
