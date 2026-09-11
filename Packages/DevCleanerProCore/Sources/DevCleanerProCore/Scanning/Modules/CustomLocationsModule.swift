import Foundation

/// M11 — folders the user added themselves (FR-5.1).
///
/// The only module whose roots come from configuration rather than code, and the only one that
/// cannot know anything about what it is looking at. So instead of classifying, it does what the
/// built-in modules do structurally: builds a real recursive tree so the user can drill down and
/// see where the weight actually sits, rather than a flat list of top-level folder names.
public struct CustomLocationsModule: ScanModule {
    private let customRoots: [CustomRoot]

    public init(customRoots: [CustomRoot]) {
        self.customRoots = customRoots
    }

    public var descriptor: ModuleDescriptor {
        ModuleDescriptor(
            id: "custom",
            title: "Custom locations",
            systemImage: "folder.badge.gearshape"
        )
    }

    /// Matches the design's maximum tree depth: module row, then four levels beneath it.
    private static let maxDepth = 4

    public var roots: [AllowedRoot] {
        // A user who deliberately added a folder means the folder itself, not just its contents.
        customRoots.map { AllowedRoot($0.url, deletableItself: true) }
    }

    public func isAvailable(_ ctx: ScanContext) async -> Bool {
        !ctx.config.customRoots.isEmpty
    }

    public func scan(_ ctx: ScanContext) async throws -> ScanNode {
        var nodes: [ScanNode] = []

        for root in ctx.config.customRoots {
            ctx.progress("Measuring \(root.title)")
            let url = root.url

            guard ctx.exists(url) else {
                // A folder that has gone away is worth saying so, rather than vanishing from the
                // list and leaving the user wondering where their setting went.
                nodes.append(ScanNode(
                    id: nodeID(root.id),
                    title: root.title,
                    subtitle: "\(root.path) — folder not found",
                    size: nil,
                    risk: .info,
                    action: .none,
                    isAdvisory: true
                ))
                continue
            }

            switch root.groupBy {
            case .flat:
                let size = await ctx.sizer.size(of: url, budget: .seconds(120))
                nodes.append(ScanNode(
                    id: nodeID(root.id),
                    title: root.title,
                    subtitle: [root.path, size?.unreadableFragment]
                        .compactMap { $0 }.joined(separator: " · "),
                    url: url,
                    size: size?.bytes,
                    risk: root.risk,
                    action: root.risk == .info ? .none : .removePath(url)
                ))

            case .children:
                guard let tree = await ctx.sizer.tree(of: url, maxDepth: Self.maxDepth) else {
                    nodes.append(ScanNode(
                        id: nodeID(root.id),
                        title: root.title,
                        subtitle: "\(root.path) — too large to measure quickly",
                        url: url,
                        size: nil,
                        risk: root.risk,
                        action: root.risk == .info ? .none : .removePath(url)
                    ))
                    continue
                }
                nodes.append(node(for: root, at: "", url: url, tree: tree, depth: 0))
            }
        }

        let count = ctx.config.customRoots.count
        return ScanNode(
            id: descriptor.id,
            title: descriptor.title,
            subtitle: "\(count) folder\(count == 1 ? "" : "s") you added · "
                + "scanned in full, like the built-in modules",
            size: nodes.reduce(Int64(0)) { $0 + $1.byteCount },
            risk: .safe,
            children: nodes
        )
    }

    /// Turns the flat path→size map into the nested tree the UI walks.
    ///
    /// Subdirectories are recursed into; everything else at this level is the difference between
    /// the directory's own total and the sum of its subdirectories — shown as one "files here"
    /// row so the arithmetic visibly adds up instead of leaving an unexplained gap.
    private func node(
        for root: CustomRoot,
        at relativePath: String,
        url: URL,
        tree: DirectoryTree,
        depth: Int
    ) -> ScanNode {
        let size = tree.size(at: relativePath)
        let title = relativePath.isEmpty
            ? root.title
            : (relativePath.split(separator: "/").last.map(String.init) ?? relativePath)

        var children: [ScanNode] = []
        var accountedFor: Int64 = 0

        if depth < Self.maxDepth {
            for name in tree.subdirectories(of: relativePath).sorted() {
                let childPath = relativePath.isEmpty ? name : "\(relativePath)/\(name)"
                let child = node(
                    for: root,
                    at: childPath,
                    url: url.appending(path: name),
                    tree: tree,
                    depth: depth + 1
                )
                accountedFor += child.byteCount
                children.append(child)
            }
        }

        let loose = size.bytes - accountedFor
        if !children.isEmpty, loose > 0 {
            children.append(ScanNode(
                id: nodeID("\(root.id)/\(relativePath)/__files"),
                title: "Files in this folder",
                subtitle: "not inside any subfolder",
                url: url,
                size: loose,
                risk: root.risk,
                // Removing these individually is not something this module can express, so the
                // row explains the remainder rather than pretending to act on it.
                action: .none,
                isAdvisory: true
            ))
        }

        let idPath = relativePath.isEmpty ? root.id : "\(root.id)/\(relativePath)"
        return ScanNode(
            id: nodeID(idPath),
            title: title,
            subtitle: relativePath.isEmpty
                ? [root.path, size.unreadableFragment].compactMap { $0 }.joined(separator: " · ")
                : (size.unreadableFragment ?? "\(size.fileCount) file"
                   + (size.fileCount == 1 ? "" : "s") + " inside"),
            url: url,
            size: size.bytes,
            risk: root.risk,
            action: root.risk == .info ? .none : .removePath(url),
            children: children
        )
    }
}
