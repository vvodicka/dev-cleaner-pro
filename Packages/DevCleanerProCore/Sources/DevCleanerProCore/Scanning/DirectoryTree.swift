import Foundation

/// Sizes for every directory within a bounded depth of a root, from **one** filesystem walk.
///
/// The naive way to build a recursive tree is to size each directory and then size each of its
/// children, which walks the same files once per level — quadratic in depth, and on a deep tree
/// that is the difference between two seconds and two minutes. This walks once and attributes
/// each file's size to every ancestor it belongs to.
public struct DirectoryTree: Sendable {
    /// Directory path relative to the root (`""` is the root itself) → total size beneath it.
    public let sizes: [String: DirectorySize]
    /// Immediate subdirectory names, keyed the same way. Empty for anything at `maxDepth`.
    public let children: [String: [String]]

    public func size(at relativePath: String) -> DirectorySize {
        sizes[relativePath] ?? .zero
    }

    public func subdirectories(of relativePath: String) -> [String] {
        children[relativePath] ?? []
    }

    public var total: DirectorySize { size(at: "") }
}

extension DirectorySizer {
    /// Walks `root` once and returns sizes for every directory down to `maxDepth`.
    ///
    /// Files below `maxDepth` still count toward their ancestors — the depth limit bounds how
    /// much detail the tree shows, never what the totals include.
    public func tree(
        of root: URL,
        maxDepth: Int,
        budget: Duration = .seconds(120)
    ) async -> DirectoryTree? {
        await withTaskGroup(of: DirectoryTree?.self, returning: DirectoryTree?.self) { group in
            group.addTask { Self.buildTree(root, maxDepth: maxDepth) }
            group.addTask {
                try? await Task.sleep(for: budget)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private static func buildTree(_ root: URL, maxDepth: Int) -> DirectoryTree? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return nil }

        let keys: Set<URLResourceKey> = [
            .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
            .isDirectoryKey, .isSymbolicLinkKey, .linkCountKey
        ]

        var sizes: [String: DirectorySize] = ["": .zero]
        var children: [String: Set<String>] = [:]
        var countedInodes: Set<InodeKey> = []
        nonisolated(unsafe) var unreadable = 0

        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: { _, _ in
                unreadable += 1
                return true
            }
        ) else { return nil }

        let rootComponents = root.standardizedFileURL.pathComponents.count
        var seen = 0

        for case let entry as URL in enumerator {
            seen += 1
            if seen % 2_000 == 0, Task.isCancelled { return nil }

            guard let values = try? entry.resourceValues(forKeys: keys) else {
                unreadable += 1
                continue
            }

            let components = Array(
                entry.standardizedFileURL.pathComponents.dropFirst(rootComponents)
            )
            guard !components.isEmpty else { continue }

            if values.isDirectory == true {
                // Record the directory only if it is shallow enough to be shown — but keep
                // walking regardless. Calling `skipDescendants()` here was a bug: it skipped the
                // *files* below too, so a deep tree like `~/.gradle/caches/modules-2/...`
                // reported 211 MB against an actual 595 MB. The depth limit bounds how much
                // detail the tree shows, never what the totals include.
                let depth = components.count
                guard depth <= maxDepth else { continue }
                let path = components.joined(separator: "/")
                let parent = components.dropLast().joined(separator: "/")
                sizes[path] = sizes[path] ?? .zero
                children[parent, default: []].insert(components[components.count - 1])
                continue
            }

            // Hard links: the same bytes reached by a second path (see `DirectorySizer`).
            if (values.linkCount ?? 1) > 1 {
                guard let key = InodeKey(path: entry.path) else { continue }
                guard countedInodes.insert(key).inserted else { continue }
            }

            let bytes = Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
            let contribution = DirectorySize(bytes: bytes, fileCount: 1)

            // Attribute to every ancestor within the shown depth, and always to the root.
            sizes["", default: .zero] += contribution
            let ancestorCount = min(components.count - 1, maxDepth)
            guard ancestorCount > 0 else { continue }
            for depth in 1...ancestorCount {
                let path = components.prefix(depth).joined(separator: "/")
                sizes[path, default: .zero] += contribution
            }
        }

        sizes["", default: .zero] += DirectorySize(unreadableCount: unreadable)
        return DirectoryTree(
            sizes: sizes,
            children: children.mapValues { Array($0) }
        )
    }
}
