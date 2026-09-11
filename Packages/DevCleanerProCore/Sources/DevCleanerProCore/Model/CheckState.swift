import Foundation

/// Tri-state checkbox value. `partial` is the design's "mixed": some descendants selected.
public enum CheckState: String, Sendable, Hashable {
    case off
    case on
    case partial

    /// Clicking cycles straight to on or off — never into partial, which only ever results from
    /// children disagreeing.
    public var toggled: CheckState {
        self == .on ? .off : .on
    }

    /// The glyph the design draws inside the box: a tick, an en dash, or nothing.
    public var mark: String {
        switch self {
        case .on: "✓"
        case .partial: "–"
        case .off: ""
        }
    }
}
