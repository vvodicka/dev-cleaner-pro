import Foundation

/// How much it costs the user to lose the thing being deleted.
///
/// The raw values are the vocabulary of `docs/03-modules-spec.md` and of `config.json`.
/// The design calls the middle level "Rebuild"; see `displayLabel`.
public enum Risk: String, Codable, Sendable, CaseIterable {
    /// Pure cache. Regenerated automatically, no cost.
    case safe
    /// Re-download or recompile needed.
    case moderate
    /// User data or device state.
    case careful
    /// Not deletable by this app — shown for honesty about totals.
    case info

    /// The label shown in the risk badge. `moderate` reads as "Rebuild" per the design.
    public var displayLabel: String {
        switch self {
        case .safe: "Safe"
        case .moderate: "Rebuild"
        case .careful: "Careful"
        case .info: "Info"
        }
    }

    /// Ordering for roll-up. `info` sits at the bottom: it means "not deletable", not "safe to
    /// lose", so it must never outrank a real warning coming from a child.
    public var severity: Int {
        switch self {
        case .info: 0
        case .safe: 1
        case .moderate: 2
        case .careful: 3
        }
    }

    /// Prefix of this level's asset-catalog colours. The badge needs three — the app appends
    /// `Fill`, `Text` or `Border`, e.g. `RiskRebuildFill`. These twelve colours are the only
    /// hard-coded hues in the app; everything else is a system semantic colour.
    public var colorAssetPrefix: String {
        switch self {
        case .safe: "RiskSafe"
        case .moderate: "RiskRebuild"
        case .careful: "RiskCareful"
        case .info: "RiskInfo"
        }
    }

    /// One-line explanation, used in the badge tooltip and the Settings risk column.
    public var explanation: String {
        switch self {
        case .safe: "Regenerated automatically, no cost"
        case .moderate: "Re-download or recompile needed"
        case .careful: "User data or device state"
        case .info: "Not deletable by DevCleanerPro"
        }
    }

    /// Accepts the design's `rebuild` spelling as an alias for `moderate`, so a hand-edited
    /// `config.json` works either way.
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw.lowercased() {
        case "safe": self = .safe
        case "moderate", "rebuild": self = .moderate
        case "careful": self = .careful
        case "info": self = .info
        default:
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath,
                      debugDescription: "Unknown risk \"\(raw)\". Expected safe, moderate, careful or info.")
            )
        }
    }
}
