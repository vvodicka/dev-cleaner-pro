import Foundation

/// A folder the user added by hand, scanned alongside the built-in modules (FR-5.1).
public struct CustomRoot: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    /// Stored as written, `~` included, so the file stays readable and portable.
    public var path: String
    public var risk: Risk
    public var groupBy: GroupBy

    public enum GroupBy: String, Codable, Sendable {
        /// One child node per direct subfolder.
        case children
        /// A single node for the whole folder.
        case flat
    }

    public init(
        id: String,
        title: String,
        path: String,
        risk: Risk = .moderate,
        groupBy: GroupBy = .children
    ) {
        self.id = id
        self.title = title
        self.path = path
        self.risk = risk
        self.groupBy = groupBy
    }

    public var url: URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }
}

/// Everything the user can configure.
///
/// This file is the single source of truth for these settings. Doc 02 defined
/// `minItemSizeMB`, `autoScanOnLaunch` and `disabledModules` twice — once here and once in
/// UserDefaults — which would have meant two answers to the same question. UserDefaults now
/// holds only the delete mode and the freed-bytes statistics (`docs/00-decisions.md`).
public struct UserConfig: Codable, Sendable, Equatable {
    public var version: Int
    /// Items below this are hidden but still counted in their parent's size (doc 03).
    public var minItemSizeMB: Int
    public var autoScanOnLaunch: Bool
    /// Extra confirmation before deleting anything marked Careful. Taken from the design, which
    /// placed the switch on the Custom locations tab; it is global, so it lives in General.
    public var warnOnCareful: Bool
    public var disabledModules: [String]
    public var customRoots: [CustomRoot]
    /// Set once the launch warning has been dismissed with "don't show this again". Stored here
    /// rather than in UserDefaults so it travels with the rest of the configuration.
    public var disclaimerAcknowledged: Bool

    public static let currentVersion = 1

    public static let defaults = UserConfig(
        version: currentVersion,
        // Show everything by default. Hiding anything under 50 MB made the first impression of a
        // module a handful of rows with no explanation for the gap between them and the total.
        minItemSizeMB: 0,
        autoScanOnLaunch: true,
        warnOnCareful: true,
        disabledModules: [],
        customRoots: [],
        disclaimerAcknowledged: false
    )

    public init(
        version: Int = currentVersion,
        minItemSizeMB: Int = 0,
        autoScanOnLaunch: Bool = true,
        warnOnCareful: Bool = true,
        disabledModules: [String] = [],
        customRoots: [CustomRoot] = [],
        disclaimerAcknowledged: Bool = false
    ) {
        self.version = version
        self.minItemSizeMB = minItemSizeMB
        self.autoScanOnLaunch = autoScanOnLaunch
        self.warnOnCareful = warnOnCareful
        self.disabledModules = disabledModules
        self.customRoots = customRoots
        self.disclaimerAcknowledged = disclaimerAcknowledged
    }

    /// Every key is optional on the way in, so a partially hand-written file still loads and
    /// simply picks up defaults for what it omits.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self.defaults
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? d.version
        minItemSizeMB = try c.decodeIfPresent(Int.self, forKey: .minItemSizeMB) ?? d.minItemSizeMB
        autoScanOnLaunch = try c.decodeIfPresent(Bool.self, forKey: .autoScanOnLaunch)
            ?? d.autoScanOnLaunch
        warnOnCareful = try c.decodeIfPresent(Bool.self, forKey: .warnOnCareful) ?? d.warnOnCareful
        disabledModules = try c.decodeIfPresent([String].self, forKey: .disabledModules)
            ?? d.disabledModules
        customRoots = try c.decodeIfPresent([CustomRoot].self, forKey: .customRoots) ?? d.customRoots
        disclaimerAcknowledged = try c.decodeIfPresent(
            Bool.self, forKey: .disclaimerAcknowledged
        ) ?? d.disclaimerAcknowledged
    }

    public var minItemSizeBytes: Int64 {
        Int64(max(0, minItemSizeMB)) * 1_048_576
    }

    public func isEnabled(_ moduleID: String) -> Bool {
        !disabledModules.contains(moduleID)
    }
}
