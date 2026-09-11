import Foundation

/// Where deleted items go. Command nodes ignore this entirely — a tool invocation cannot be
/// undone, and the confirmation sheet says so in its own section (doc 03, `docs/00-decisions.md` #4).
public enum DeleteMode: String, Codable, Sendable, CaseIterable {
    case trash
    case permanent

    public var segmentLabel: String {
        switch self {
        case .trash: "Move to Trash"
        case .permanent: "Delete permanently"
        }
    }

    /// Title of the confirmation sheet's action button.
    public var confirmButtonTitle: String {
        switch self {
        case .trash: "Move to Trash"
        case .permanent: "Delete Permanently"
        }
    }

    /// Trash mode does not free space until the Trash is emptied, so the toast must not claim
    /// it did (doc 02).
    public func toastMessage(freed bytes: Int64) -> String {
        switch self {
        case .trash: "Moved \(ByteFormatting.string(bytes)) to Trash"
        case .permanent: "Freed \(ByteFormatting.string(bytes))"
        }
    }

    public var offersEmptyTrash: Bool { self == .trash }
}
