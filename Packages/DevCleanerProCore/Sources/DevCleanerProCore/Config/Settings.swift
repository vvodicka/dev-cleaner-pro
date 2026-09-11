import Foundation

/// The two things that belong in UserDefaults rather than `config.json`: the delete mode, which
/// is a transient UI preference, and the freed-bytes statistics, which are not configuration at
/// all. Everything else lives in `config.json` (`docs/00-decisions.md`).
public struct Settings: Sendable {
    // UserDefaults is documented as thread-safe but is not marked Sendable, so the annotation
    // states what the framework guarantees rather than opting out of a real check.
    nonisolated(unsafe) private let defaults: UserDefaults

    public enum Key {
        public static let deleteMode = "deleteMode"
        public static let totalBytesFreed = "stats.totalBytesFreed"
        public static let sessions = "stats.sessions"
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var deleteMode: DeleteMode {
        get {
            guard let raw = defaults.string(forKey: Key.deleteMode),
                  let mode = DeleteMode(rawValue: raw)
            else { return .trash }   // FR-4.1: Trash is the default
            return mode
        }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Key.deleteMode) }
    }
}
