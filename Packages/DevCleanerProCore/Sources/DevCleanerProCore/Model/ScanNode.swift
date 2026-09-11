import Foundation

/// One row in the tree.
///
/// Modules are depth-0 nodes of a single unified tree (see `docs/00-decisions.md` #7), so the
/// same type describes a module, a group, an item and a sub-item. Depth runs 0...4.
public struct ScanNode: Identifiable, Sendable, Hashable {
    /// Stable across rescans — path- or UUID-derived, never index-derived, so selection and
    /// expansion survive a rescan. Convention: `"<moduleID>/<relative-path-or-uuid>"`.
    public let id: String
    public var title: String
    /// "last used Apr 15 2025", "iOS 26.4", "12 images", "3 unreadable".
    public var subtitle: String?
    /// For Reveal in Finder and Copy path. Command nodes may have none.
    public var url: URL?
    /// Allocated size on disk in bytes. `nil` means genuinely unknown (Time Machine snapshots,
    /// unreadable protected paths) and renders as "—" rather than "0 B".
    public var size: Int64?
    public var risk: Risk
    public var action: DeleteAction
    public var children: [ScanNode]
    /// Non-nil means the checkbox is visible but disabled, with this text in `.help()`.
    /// e.g. "Simulator is booted — shut it down to delete".
    public var blockedReason: String?
    /// Shown on purpose even though nothing here can be ticked.
    ///
    /// The distinction that matters: 59 GB of SIP-protected simulator downloads is worth a row
    /// because the user would want to know it is there and what to do about it. A folder the app
    /// merely failed to classify is not — it reads as "safe to remove" while refusing to remove
    /// anything, which is worse than leaving it out. Rows that are neither selectable nor
    /// advisory are pruned before display.
    public var isAdvisory: Bool

    public init(
        id: String,
        title: String,
        subtitle: String? = nil,
        url: URL? = nil,
        size: Int64? = nil,
        risk: Risk = .safe,
        action: DeleteAction = .none,
        children: [ScanNode] = [],
        blockedReason: String? = nil,
        isAdvisory: Bool = false
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.url = url
        self.size = size
        self.risk = risk
        self.action = action
        self.children = children
        self.blockedReason = blockedReason
        self.isAdvisory = isAdvisory
    }

    /// Carries no action of its own. Note that this is *not* the same as "cannot be checked":
    /// groups and module rows carry no action either, and they are very much selectable.
    public var isInfo: Bool { action == .none }
    public var isBlocked: Bool { blockedReason != nil }
    /// Has an action of its own that can be carried out right now.
    public var isDeletable: Bool { !isInfo && !isBlocked }
    public var hasChildren: Bool { !children.isEmpty }

    /// The risk actually shown on the row: the most severe risk anywhere in this subtree.
    ///
    /// Without this a group reads "Safe" while a child three levels down is "Careful", which is
    /// worse than no badge at all — it is an assurance the tree cannot keep. `info` never wins,
    /// because "we won't touch this" is not a severity.
    public var rolledUpRisk: Risk {
        var worst = risk == .info ? Risk.safe : risk
        for child in children {
            let childRisk = child.rolledUpRisk
            if childRisk.severity > worst.severity { worst = childRisk }
        }
        // A node that is itself purely informational keeps saying so when nothing under it is
        // selectable either.
        if risk == .info, !isSelectable { return .info }
        return worst
    }

    /// Whether this row gets a checkbox.
    ///
    /// A group or module row has no action of its own, but checking it should select everything
    /// underneath — so it is selectable whenever anything beneath it is. Only a genuine dead end
    /// (an info leaf, or a subtree made entirely of info and blocked rows) gets the ⓘ instead.
    public var isSelectable: Bool {
        if isDeletable { return true }
        return children.contains { $0.isSelectable }
    }

    /// Size for arithmetic. Unknown sizes contribute nothing to totals.
    public var byteCount: Int64 { size ?? 0 }
}

extension ScanNode {
    /// Depth-first walk, self first.
    public func forEachNode(_ body: (ScanNode) -> Void) {
        body(self)
        for child in children { child.forEachNode(body) }
    }

    public func node(withID target: ScanNode.ID) -> ScanNode? {
        if id == target { return self }
        for child in children {
            if let hit = child.node(withID: target) { return hit }
        }
        return nil
    }

    /// Drops subtrees below the size filter, keeping the parent's size intact
    /// (doc 03: "items below minItemSizeMB are hidden but still counted in parent size").
    ///
    /// The filter applies to info and blocked nodes too. An earlier version exempted them on the
    /// grounds that "the tree never hides what it cannot delete", but that rule is about a
    /// significant blocked item — a booted 4 GB simulator — not about a 4 KB `.DS_Store` the app
    /// merely declined to classify. Exempting them buried the useful rows under dozens of
    /// four-kilobyte ones. A node with surviving children is always kept, so a group never
    /// disappears out from under its contents.
    public func filtered(minimumBytes: Int64) -> ScanNode? {
        var copy = self
        copy.children = children.compactMap { $0.filtered(minimumBytes: minimumBytes) }
        if !copy.children.isEmpty { return copy }
        return byteCount < minimumBytes ? nil : copy
    }

    /// Drops rows that can neither be ticked nor justify their presence.
    ///
    /// A node survives if it is selectable, if it was marked advisory, or if anything beneath it
    /// survived — so a group keeps its shape while the dead ends inside it go.
    public func pruningDeadEnds() -> ScanNode? {
        var copy = self
        copy.children = children.compactMap { $0.pruningDeadEnds() }
        if isSelectable || isAdvisory || !copy.children.isEmpty { return copy }
        return nil
    }

    /// Sorts every level. Unknown sizes sink to the bottom of a size sort.
    public func sorted(by order: TreeSortOrder) -> ScanNode {
        var copy = self
        copy.children = children
            .map { $0.sorted(by: order) }
            .sorted { lhs, rhs in
                switch order {
                case .sizeDescending:
                    if lhs.size == nil, rhs.size != nil { return false }
                    if rhs.size == nil, lhs.size != nil { return true }
                    if lhs.byteCount != rhs.byteCount { return lhs.byteCount > rhs.byteCount }
                    return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
                case .nameAscending:
                    return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
                }
            }
        return copy
    }
}

/// Tree sort order. The design's Item and Size column headers toggle between these.
///
/// Named `TreeSortOrder` rather than `SortOrder` because SwiftUI ships a `SortOrder` of its own,
/// and an unqualified `SortOrder` in a view file resolves ambiguously.
public enum TreeSortOrder: String, Sendable, CaseIterable {
    case sizeDescending
    case nameAscending
}
