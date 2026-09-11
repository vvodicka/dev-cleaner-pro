import Foundation

/// What deleting a node actually does.
public enum DeleteAction: Sendable, Hashable {
    /// Remove one path — to the Trash or permanently, per the current mode.
    case removePath(URL)
    /// Remove several paths as one unit. Used where a logical item spans folders,
    /// e.g. an AVD's `.avd` directory plus its `.ini`, or a JetBrains version's
    /// Caches + Application Support + Logs.
    case removePaths([URL])
    /// Run a tool. Always irreversible — the Trash/permanent toggle does not apply,
    /// and the confirmation sheet says so in its own section.
    case command(executable: String, args: [String], displayName: String)
    /// Info node. Nothing to delete.
    case none

    public var isCommand: Bool {
        if case .command = self { return true }
        return false
    }

    /// Every filesystem path this action would touch. Empty for commands and info nodes.
    public var paths: [URL] {
        switch self {
        case .removePath(let url): [url]
        case .removePaths(let urls): urls
        case .command, .none: []
        }
    }
}
