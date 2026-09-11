import Foundation

/// Tri-state selection over the whole tree.
///
/// Mirrors the logic the design ships in `DevSweepWindow.dc.html` (`toggleCheck`, `roll`,
/// `selection`): checking a node applies to every descendant, parents roll up to `partial` when
/// their children disagree, and **info and blocked nodes are skipped by both propagation and
/// roll-up** — so a group whose only unchecked child is a booted simulator still reads as fully
/// selected rather than being stuck on `partial` forever.
public struct SelectionModel: Sendable, Equatable {
    public private(set) var states: [ScanNode.ID: CheckState]

    public init(states: [ScanNode.ID: CheckState] = [:]) {
        self.states = states
    }

    public func state(of id: ScanNode.ID) -> CheckState {
        states[id] ?? .off
    }

    public var isEmpty: Bool {
        !states.values.contains { $0 != .off }
    }

    public mutating func clear() {
        states.removeAll()
    }

    /// Drops one node's state — used after a successful deletion, so an item that is gone stops
    /// being counted while a blocked one stays checked for a retry.
    public mutating func forget(_ id: ScanNode.ID) {
        states[id] = nil
    }

    /// Re-derives every container's state from the tree as it now is, and discards states for
    /// nodes that no longer exist.
    ///
    /// Needed after a scan or a deletion. Without it, deleting the children of a group left the
    /// group stuck on `partial` with nothing beneath it selected — the state was computed once
    /// and never revisited when the tree underneath changed.
    public mutating func resync(with roots: [ScanNode]) {
        var live: Set<ScanNode.ID> = []
        for root in roots {
            root.forEachNode { live.insert($0.id) }
        }
        states = states.filter { live.contains($0.key) }
        rollUp(roots)
    }

    // MARK: - Mutation

    /// Flips a node and reconciles the whole tree.
    public mutating func toggle(_ node: ScanNode, in roots: [ScanNode]) {
        guard node.isDeletable || node.hasChildren else { return }
        set(node, to: state(of: node.id).toggled, in: roots)
    }

    public mutating func set(_ node: ScanNode, to value: CheckState, in roots: [ScanNode]) {
        apply(value, from: node)
        rollUp(roots)
    }

    /// "Select all safe" and "Select all" from the row and module context menus (FR-3.3).
    public mutating func selectAll(
        under node: ScanNode,
        in roots: [ScanNode],
        matching predicate: (ScanNode) -> Bool
    ) {
        func walk(_ n: ScanNode) {
            if n.isDeletable, predicate(n) {
                states[n.id] = .on
                // A selected node covers its descendants; marking them keeps the boxes honest.
                for child in n.children { markSubtree(child, .on) }
                return
            }
            for child in n.children { walk(child) }
        }
        walk(node)
        rollUp(roots)
    }

    /// Sets a subtree, skipping anything that cannot be selected.
    private mutating func apply(_ value: CheckState, from node: ScanNode) {
        guard !node.isInfo || node.hasChildren else { return }
        if node.isDeletable { states[node.id] = value }
        for child in node.children { apply(value, from: child) }
    }

    private mutating func markSubtree(_ node: ScanNode, _ value: CheckState) {
        if node.isDeletable { states[node.id] = value }
        for child in node.children { markSubtree(child, value) }
    }

    /// Recomputes every container's state bottom-up from its selectable children.
    private mutating func rollUp(_ roots: [ScanNode]) {
        for root in roots { _ = reconcile(root) }
    }

    @discardableResult
    private mutating func reconcile(_ node: ScanNode) -> CheckState? {
        guard node.hasChildren else {
            return node.isDeletable ? state(of: node.id) : nil
        }
        let childStates = node.children.compactMap { reconcile($0) }
        guard !childStates.isEmpty else {
            // Every child is info or blocked, so the parent stands on its own.
            return node.isDeletable ? state(of: node.id) : nil
        }
        let rolled: CheckState =
            childStates.allSatisfy { $0 == .on } ? .on
            : childStates.allSatisfy { $0 == .off } ? .off
            : .partial
        states[node.id] = rolled
        return rolled
    }

    // MARK: - Totals

    /// What deletion will actually operate on: the highest selected node that has something to
    /// do, never both a parent and its children.
    ///
    /// Container nodes — a module row, or a group with no path of its own — carry no action, so
    /// the walk descends through them.
    public func deletionTargets(in roots: [ScanNode]) -> [ScanNode] {
        var targets: [ScanNode] = []
        func visit(_ node: ScanNode) {
            if state(of: node.id) == .on, node.isDeletable {
                targets.append(node)
                return   // deleting this covers everything beneath it
            }
            for child in node.children { visit(child) }
        }
        for root in roots { visit(root) }
        return Self.removingNestedPaths(targets)
    }

    /// Drops any target that sits inside another target, **across modules**.
    ///
    /// Within one tree the walk above already stops at the topmost selected node. Across trees it
    /// cannot: a custom location pointed at `~/others` and the Project build output module both
    /// legitimately offer `~/others/app/node_modules`. Selecting both would count those bytes
    /// twice in the "will be freed" figure and then try to delete the same path a second time,
    /// which fails and reads as an error for something that in fact worked.
    static func removingNestedPaths(_ targets: [ScanNode]) -> [ScanNode] {
        // Shortest paths first, so a container is always seen before what it contains.
        let ordered = targets.sorted { lhs, rhs in
            (lhs.url?.pathComponents.count ?? 0) < (rhs.url?.pathComponents.count ?? 0)
        }
        var kept: [ScanNode] = []
        var keptPaths: [[String]] = []

        for target in ordered {
            guard let components = target.url?.standardizedFileURL.pathComponents else {
                // Command actions have no path and can never nest inside one.
                kept.append(target)
                continue
            }
            let isNested = keptPaths.contains { parent in
                components.count > parent.count
                    && Array(components.prefix(parent.count)) == parent
            }
            guard !isNested else { continue }
            kept.append(target)
            keptPaths.append(components)
        }
        // Restore the original order so the confirmation sheet still reads module by module.
        let keptIDs = Set(kept.map(\.id))
        return targets.filter { keptIDs.contains($0.id) }
    }

    /// Footer totals.
    ///
    /// The count is the number of deletion targets, not the number of checked leaves — it is the
    /// same number the confirmation sheet lists and the same number of operations that will run.
    /// The design counted leaves, which would say "3 items" for one DerivedData folder it then
    /// removes in a single step.
    public func totals(in roots: [ScanNode]) -> (bytes: Int64, count: Int) {
        let targets = deletionTargets(in: roots)
        return (targets.reduce(0) { $0 + $1.byteCount }, targets.count)
    }

    /// Deletion targets grouped by module, in the order the modules appear — the shape the
    /// confirmation sheet and the deletion engine both want.
    public func targetsByModule(in roots: [ScanNode]) -> [(moduleID: String, nodes: [ScanNode])] {
        roots.compactMap { root in
            let nodes = deletionTargets(in: [root])
            return nodes.isEmpty ? nil : (root.id, nodes)
        }
    }
}
