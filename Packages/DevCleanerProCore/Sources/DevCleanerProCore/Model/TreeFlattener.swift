import Foundation

/// One visible row of the tree.
public struct FlatRow: Identifiable, Sendable {
    public let node: ScanNode
    /// 0 for a module row, up to 4. Drives the design's `14 + 19 × depth` indent.
    public let depth: Int
    /// The module this row belongs to, for grouping in the confirmation sheet and for
    /// "Rescan module".
    public let moduleID: String

    public var id: ScanNode.ID { node.id }
    public var isModuleRow: Bool { depth == 0 }
    public var indent: CGFloat { CGFloat(14 + depth * 19) }
    /// Module rows are 34 pt, everything else 30 pt (component spec).
    public var height: CGFloat { isModuleRow ? 34 : 30 }
}

/// Turns the per-module trees into the flat list of rows the `List` renders.
///
/// Only expanded branches are walked, so cost is proportional to what is on screen rather than
/// to the size of the whole tree — the same trick the design's `flatten()` uses, and what keeps
/// eleven modules' worth of deep trees in a single list responsive.
public struct TreeFlattener: Sendable {
    public init() {}

    /// - Parameters:
    ///   - order: modules in sidebar order; results are keyed by module ID.
    ///   - minimumBytes: hides small items while leaving their size in the parent's total.
    public func rows(
        modules order: [String],
        results: [String: ScanNode],
        expanded: Set<ScanNode.ID>,
        sortedBy sort: TreeSortOrder,
        minimumBytes: Int64
    ) -> [FlatRow] {
        var rows: [FlatRow] = []
        for moduleID in order {
            guard let root = prepared(
                results[moduleID],
                sortedBy: sort,
                minimumBytes: minimumBytes
            ) else { continue }
            append(root, depth: 0, moduleID: moduleID, expanded: expanded, into: &rows)
        }
        return rows
    }

    /// The filtered and sorted tree for one module, or nil when nothing survives.
    /// A module row itself is never filtered away — an empty module still reports its own size.
    public func prepared(
        _ root: ScanNode?,
        sortedBy sort: TreeSortOrder,
        minimumBytes: Int64
    ) -> ScanNode? {
        guard var root else { return nil }
        root.children = root.children.compactMap {
            $0.pruningDeadEnds()?.filtered(minimumBytes: minimumBytes)
        }
        return root.sorted(by: sort)
    }

    private func append(
        _ node: ScanNode,
        depth: Int,
        moduleID: String,
        expanded: Set<ScanNode.ID>,
        into rows: inout [FlatRow]
    ) {
        rows.append(FlatRow(node: node, depth: depth, moduleID: moduleID))
        guard expanded.contains(node.id) else { return }
        for child in node.children {
            append(child, depth: depth + 1, moduleID: moduleID, expanded: expanded, into: &rows)
        }
    }
}
