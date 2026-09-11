import Foundation

/// Exactly what a confirmed deletion will do, grouped the way the confirmation sheet shows it.
///
/// Built before anything is touched, so the sheet describes real operations rather than a
/// summary. The design's mock renders `rm -rf …` for every row, but Trash mode never runs `rm` —
/// so each operation is worded from the mode and the action it actually has
/// (`docs/00-decisions.md` #14).
public struct DeletionPlan: Sendable {
    public struct Item: Sendable, Identifiable {
        public let node: ScanNode
        public let moduleID: String
        /// One line per path, or the literal command. Shown verbatim in the sheet.
        public let operations: [String]
        /// Command items run a tool and cannot be undone whatever the mode says. The sheet marks
        /// them and explains why once.
        public let isCommand: Bool

        public var id: ScanNode.ID { node.id }
        public var bytes: Int64 { node.byteCount }
    }

    public struct Group: Sendable, Identifiable {
        public let moduleID: String
        public let title: String
        public let items: [Item]

        public var id: String { moduleID }
        public var bytes: Int64 { items.reduce(0) { $0 + $1.bytes } }
    }

    public let mode: DeleteMode
    public let groups: [Group]

    public var items: [Item] { groups.flatMap(\.items) }
    public var totalBytes: Int64 { groups.reduce(0) { $0 + $1.bytes } }
    public var totalCount: Int { groups.reduce(0) { $0 + $1.items.count } }
    public var isEmpty: Bool { groups.isEmpty }

    /// Whether any item ignores the delete mode. Drives the sheet's one-line caveat.
    public var hasCommands: Bool { items.contains { $0.isCommand } }

    /// True when the selection includes user data or device state, so `warnOnCareful` can ask
    /// for a second look.
    public var hasCareful: Bool { items.contains { $0.node.rolledUpRisk == .careful } }

    public init(
        mode: DeleteMode,
        selection: SelectionModel,
        roots: [ScanNode],
        titles: [String: String]
    ) {
        self.mode = mode
        self.groups = roots.compactMap { root in
            let nodes = selection.deletionTargets(in: [root])
            guard !nodes.isEmpty else { return nil }
            let items = nodes.map { node in
                Item(
                    node: node,
                    moduleID: root.id,
                    operations: Self.operations(for: node, mode: mode),
                    isCommand: node.action.isCommand
                )
            }
            return Group(moduleID: root.id, title: titles[root.id] ?? root.title, items: items)
        }
    }

    public static func operations(for node: ScanNode, mode: DeleteMode) -> [String] {
        switch node.action {
        case .removePath(let url):
            [describe(url, mode: mode)]
        case .removePaths(let urls):
            urls.map { describe($0, mode: mode) }
        case .command(let executable, let args, _):
            [([executable] + args).joined(separator: " ")]
        case .none:
            []
        }
    }

    private static func describe(_ url: URL, mode: DeleteMode) -> String {
        let path = abbreviate(url)
        return switch mode {
        case .permanent: "rm -rf \(path)"
        case .trash: "Move to Trash: \(path)"
        }
    }

    /// `~`-abbreviated, because the full `/Users/<name>/…` prefix on every line pushes the part
    /// that identifies the item off the end of the row.
    public static func abbreviate(_ url: URL) -> String {
        let home = NSHomeDirectory()
        return url.path.hasPrefix(home + "/")
            ? "~" + url.path.dropFirst(home.count)
            : url.path
    }
}
