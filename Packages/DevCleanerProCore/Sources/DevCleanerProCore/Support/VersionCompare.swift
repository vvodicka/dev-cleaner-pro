import Foundation

/// Numeric version ordering, used for the "newest is careful, older is safe" heuristic that doc
/// 03 applies to SDKs, NDKs, DeviceSupport folders and JetBrains releases.
///
/// `String.compare(options: .numeric)` rather than splitting on dots, because these names are not
/// consistently dotted — `android-36`, `2025.3`, `18.5 (22F77)` and `26.4.1` all have to sort.
public enum VersionCompare {
    public static func isAscending(_ lhs: String, _ rhs: String) -> Bool {
        lhs.compare(rhs, options: [.numeric, .caseInsensitive]) == .orderedAscending
    }

    /// The highest version in the list, or nil when empty.
    public static func highest(_ versions: [String]) -> String? {
        versions.max { isAscending($0, $1) }
    }

    /// The IDs of the highest-version item *within each group*.
    ///
    /// Grouped rather than a single global maximum because the newest iOS DeviceSupport folder
    /// and the newest watchOS one are both worth keeping, and a global maximum would mark one of
    /// them safe to delete.
    public static func highestPerGroup<T>(
        _ items: [T],
        id: (T) -> String,
        group: (T) -> String,
        version: (T) -> String
    ) -> Set<String> {
        var best: [String: (id: String, version: String)] = [:]
        for item in items {
            let g = group(item)
            let v = version(item)
            if let existing = best[g], !isAscending(existing.version, v) { continue }
            best[g] = (id(item), v)
        }
        return Set(best.values.map(\.id))
    }
}
