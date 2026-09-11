import Foundation

/// Measures directories the way `du` does: allocated size on disk, symlinks never followed, and
/// **each hard-linked file counted once**.
///
/// Doc 02 said double counting hard links was acceptable "same as `du`". That premise was simply
/// wrong — `du` deduplicates by inode — and the consequence was not academic: a React Native
/// `node_modules` on the development machine reported 26.3 GB against an actual 13.9 GB, because
/// 92 inodes (mostly `libreactnative.so`, ~150 MB each) appear at nine paths apiece. Reporting
/// 12 GB of space that deleting the folder would not reclaim is the worst kind of wrong for an
/// app whose entire job is telling you what you will get back.
///
/// APFS clones are a different case and *are* counted per copy, which is correct: each clone
/// occupies its own blocks once written to, and `du` reports them the same way.
///
/// Walks run on a dedicated concurrent queue rather than the Swift cooperative pool. Enumeration
/// is a long blocking loop, and occupying cooperative threads with it would stall the UI and the
/// rest of the scan (NFR-2 requires the UI stay responsive).
public struct DirectorySizer: Sendable {
    /// How often `Task.checkCancellation()` runs during a walk. Doc 02 specifies 2 000.
    private static let cancellationCheckInterval = 2_000



    private static let queue = DispatchQueue(
        label: "dev.vodicka.DevCleanerPro.sizer",
        qos: .utility,
        attributes: .concurrent
    )

    private static let resourceKeys: [URLResourceKey] = [
        .totalFileAllocatedSizeKey,
        .fileAllocatedSizeKey,
        .isDirectoryKey,
        .isSymbolicLinkKey,
        .isRegularFileKey,
        // Only files with more than one link can be double counted, so only those need an
        // inode remembered — the same optimisation `du` makes. Tracking every inode in a
        // million-file tree would cost far more memory than NFR-3 allows.
        .linkCountKey
    ]

    public init() {}

    // MARK: - Public API

    /// Total allocated size of everything under `url`, inclusive.
    ///
    /// A missing directory is not an error — modules list optional paths freely, and an absent
    /// one simply measures zero.
    public func size(of url: URL) async throws -> DirectorySize {
        guard FileManager.default.fileExists(atPath: url.path) else { return .zero }
        return try await walk(url)
    }

    /// Like `size(of:)` but gives up after `budget` and reports nothing rather than holding the
    /// whole module hostage.
    ///
    /// Needed because some real trees cannot be measured quickly by anyone: `~/.cocoapods/repos`
    /// holds 1.82 million files, and `du` itself takes 42 s on it. Doc 03's 60 s per-module rule
    /// assumes that never happens, so a slow entry degrades to "size unknown" and the module
    /// still returns with everything else intact.
    public func size(of url: URL, budget: Duration) async -> DirectorySize? {
        await withTaskGroup(of: DirectorySize?.self, returning: DirectorySize?.self) { group in
            group.addTask { try? await self.size(of: url) }
            group.addTask {
                try? await Task.sleep(for: budget)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// Sizes each direct child of `url` concurrently, so a module can build a group of per-folder
    /// nodes from one call. Children are returned in the order the filesystem lists them; the
    /// caller sorts.
    ///
    /// Concurrency is capped at `activeProcessorCount` — beyond that, competing walks slow each
    /// other down without finishing sooner.
    public func sizedChildren(of url: URL) async throws -> [(url: URL, size: DirectorySize)] {
        let children = try directChildren(of: url)
        guard !children.isEmpty else { return [] }

        let limit = max(1, ProcessInfo.processInfo.activeProcessorCount)
        return try await withThrowingTaskGroup(
            of: (url: URL, size: DirectorySize).self
        ) { group in
            var iterator = children.makeIterator()
            var running = 0

            while running < limit, let next = iterator.next() {
                group.addTask { (next, try await self.walk(next)) }
                running += 1
            }

            var results: [(url: URL, size: DirectorySize)] = []
            results.reserveCapacity(children.count)
            while let finished = try await group.next() {
                results.append(finished)
                if let next = iterator.next() {
                    group.addTask { (next, try await self.walk(next)) }
                }
            }
            return results
        }
    }

    /// Direct children of a directory, hidden entries included. Empty when the directory is
    /// missing or unreadable.
    public func directChildren(of url: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do {
            return try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: []
            )
        } catch {
            // Unreadable directory — the caller reports zero rather than failing the module.
            return []
        }
    }

    // MARK: - The walk

    private func walk(_ url: URL) async throws -> DirectorySize {
        try await withCheckedThrowingContinuation { continuation in
            Self.queue.async {
                do {
                    continuation.resume(returning: try Self.measure(url))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func measure(_ url: URL) throws -> DirectorySize {
        var result = DirectorySize.zero
        let fm = FileManager.default

        // A symlink or a plain file: measure it directly, do not resolve it.
        let values = try? url.resourceValues(forKeys: Set(resourceKeys))
        if values?.isSymbolicLink == true {
            return DirectorySize(bytes: allocatedSize(of: values), fileCount: 1)
        }
        if values?.isDirectory != true {
            return DirectorySize(bytes: allocatedSize(of: values), fileCount: 1)
        }

        // `errorHandler` returning true keeps the walk going past an unreadable subtree instead
        // of abandoning the whole module, and lets us count what we missed.
        // Safe despite the annotation: `measure` runs wholly on one queue thread, and the
        // enumerator calls `errorHandler` synchronously on that same thread.
        nonisolated(unsafe) var unreadable = 0
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: resourceKeys,
            options: [],
            errorHandler: { _, _ in
                unreadable += 1
                return true
            }
        ) else {
            return DirectorySize(bytes: 0, unreadableCount: 1)
        }

        var seen = 0
        var countedInodes: Set<InodeKey> = []
        for case let child as URL in enumerator {
            seen += 1
            if seen % cancellationCheckInterval == 0 {
                try Task.checkCancellation()
            }
            guard let childValues = try? child.resourceValues(forKeys: Set(resourceKeys)) else {
                unreadable += 1
                continue
            }

            // A hard-linked file reached by a second path is the same bytes on disk. Counting it
            // again would promise space that deleting this tree cannot return.
            if (childValues.linkCount ?? 1) > 1, childValues.isDirectory != true {
                guard let key = InodeKey(path: child.path) else { continue }
                guard countedInodes.insert(key).inserted else { continue }
            }

            // Directories contribute their own allocated size (the directory record itself);
            // their contents arrive as separate enumerator entries.
            result.bytes += allocatedSize(of: childValues)
            if childValues.isDirectory != true { result.fileCount += 1 }
        }

        result.unreadableCount += unreadable
        return result
    }

    /// Identity of a file on disk. Device as well as inode, because inode numbers are only
    /// unique within a volume and a scan can cross one (a custom location on an external disk).
    struct InodeKey: Hashable, Sendable {
        let device: Int32
        let inode: UInt64

        init?(path: String) {
            var info = stat()
            guard lstat(path, &info) == 0 else { return nil }
            device = info.st_dev
            inode = UInt64(info.st_ino)
        }
    }

    private static func allocatedSize(of values: URLResourceValues?) -> Int64 {
        guard let values else { return 0 }
        if let total = values.totalFileAllocatedSize { return Int64(total) }
        if let allocated = values.fileAllocatedSize { return Int64(allocated) }
        return 0
    }
}
