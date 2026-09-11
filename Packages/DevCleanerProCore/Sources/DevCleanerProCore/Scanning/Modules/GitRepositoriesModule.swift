import Foundation

/// M14 — waste inside `.git` directories.
///
/// Git never cleans up after itself on two counts, and both were found on the development
/// machine in one repository holding 15 GB for 125 tracked files:
///
/// - **Abandoned temporary packs.** While packing, git writes `objects/pack/tmp_pack_XXXXXX` and
///   renames it on success. If the operation is interrupted — a crash, a force-quit, a full disk
///   — the temporary file is left behind and nothing ever removes it. Two of them accounted for
///   14.1 GB.
/// - **Unreachable loose objects.** `git add` writes a blob immediately, so staging a large tree
///   and then not committing it leaves those objects behind until a `gc` prunes them. 33 236 of
///   them, against 144 actually reachable.
///
/// **`.git` itself is never offered for deletion, at any risk level.** It is the repository's
/// entire history, frequently the only copy, and no amount of "are you sure" makes removing it
/// from a disk-cleaning tool a reasonable thing to offer. Only the two forms of waste above are
/// actionable, and the directory as a whole appears as an information row.
public struct GitRepositoriesModule: ScanModule {
    public init() {}

    public var descriptor: ModuleDescriptor {
        ModuleDescriptor(
            id: "git",
            title: "Git repositories",
            systemImage: "arrow.triangle.branch",
            requiresTool: "git"
        )
    }

    /// Loose-object waste below this is not worth a row — every active repository has some.
    private static let looseObjectFloor: Int64 = 50 * 1_048_576

    public var roots: [AllowedRoot] {
        // The same code folders the project-artifacts module searches. Contents only: nothing
        // here should ever remove one of the user's project directories.
        ProjectArtifactsModule.searchRoots(home: URL(fileURLWithPath: NSHomeDirectory()))
            .map { AllowedRoot($0) }
    }

    public func isAvailable(_ ctx: ScanContext) async -> Bool {
        guard await ctx.shell.has("git") else { return false }
        return !ProjectArtifactsModule.searchRoots(home: ctx.home).isEmpty
    }

    public func scan(_ ctx: ScanContext) async throws -> ScanNode {
        let searchRoots = ProjectArtifactsModule.searchRoots(home: ctx.home)
        let repositories = Self.findRepositories(under: searchRoots)
        guard !repositories.isEmpty else {
            throw ScanFailure.empty("No git repositories found in your code folders")
        }
        ctx.progress("Checking \(repositories.count) git repositories")

        var children: [ScanNode] = []
        for repository in repositories {
            if let node = await inspect(repository, ctx: ctx) { children.append(node) }
        }
        guard !children.isEmpty else {
            throw ScanFailure.empty("No reclaimable space found in your git repositories")
        }

        return ScanNode(
            id: descriptor.id,
            title: descriptor.title,
            subtitle: "leftovers git does not clean up on its own · "
                + "history itself is never offered for deletion",
            size: children.reduce(Int64(0)) { $0 + $1.byteCount },
            risk: .moderate,
            children: children
        )
    }

    /// Repositories within a bounded depth of the search roots. A `.git` directory ends the
    /// descent — repositories inside repositories are a submodule's business, not this app's.
    public static func findRepositories(under searchRoots: [URL], maxDepth: Int = 3) -> [URL] {
        let fm = FileManager.default
        var found: [URL] = []

        func walk(_ directory: URL, depth: Int) {
            guard depth <= maxDepth else { return }
            if fm.fileExists(atPath: directory.appending(path: ".git").path) {
                found.append(directory)
                return
            }
            guard let children = try? fm.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { return }
            for child in children
            where (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                walk(child, depth: depth + 1)
            }
        }

        for root in searchRoots {
            if fm.fileExists(atPath: root.appending(path: ".git").path) {
                found.append(root)
            }
            walk(root, depth: 1)
        }
        return found
    }

    // MARK: - One repository

    private func inspect(_ repository: URL, ctx: ScanContext) async -> ScanNode? {
        let gitDirectory = repository.appending(path: ".git")
        // A worktree or submodule has `.git` as a file pointing elsewhere; nothing to clean here.
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: gitDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { return nil }

        var items: [ScanNode] = []

        if let abandoned = await abandonedPacks(in: gitDirectory, repository: repository, ctx: ctx) {
            items.append(abandoned)
        }
        if let loose = await looseObjects(in: repository, gitDirectory: gitDirectory, ctx: ctx) {
            items.append(loose)
        }
        guard !items.isEmpty else { return nil }

        let total = await ctx.sizer.size(of: gitDirectory, budget: .seconds(60))
        let reclaimable = items.reduce(Int64(0)) { $0 + $1.byteCount }

        return ScanNode(
            id: nodeID(Self.identifier(for: repository, home: ctx.home)),
            title: repository.lastPathComponent,
            subtitle: "\(DeletionPlan.abbreviate(gitDirectory)) is "
                + "\(ByteFormatting.string(total?.bytes)) · "
                + "\(ByteFormatting.string(reclaimable)) of it is reclaimable",
            url: gitDirectory,
            size: reclaimable,
            risk: .moderate,
            // Information only. The history is not something this app removes.
            action: .none,
            children: items,
            isAdvisory: true
        )
    }

    /// `tmp_pack_*` left behind by an interrupted pack. Nothing references them, so removing the
    /// files is exact and safe — no `gc` needed and no history touched.
    private func abandonedPacks(
        in gitDirectory: URL,
        repository: URL,
        ctx: ScanContext
    ) async -> ScanNode? {
        let packDirectory = gitDirectory.appending(path: "objects/pack")
        guard ctx.exists(packDirectory),
              let entries = try? FileManager.default.contentsOfDirectory(
                  at: packDirectory, includingPropertiesForKeys: [.fileSizeKey], options: []
              )
        else { return nil }

        let abandoned = entries.filter { $0.lastPathComponent.hasPrefix("tmp_pack") }
        guard !abandoned.isEmpty else { return nil }

        var bytes: Int64 = 0
        for file in abandoned {
            bytes += (await ctx.sizer.size(of: file, budget: .seconds(20)))?.bytes ?? 0
        }
        guard bytes > 0 else { return nil }

        return ScanNode(
            id: nodeID("\(Self.identifier(for: repository, home: ctx.home))/tmp-packs"),
            title: "Interrupted pack files",
            subtitle: "\(abandoned.count) file\(abandoned.count == 1 ? "" : "s") git left behind "
                + "when a pack was interrupted · nothing refers to them",
            url: abandoned[0],
            size: bytes,
            risk: .safe,
            action: .removePaths(abandoned)
        )
    }

    /// Loose objects that no ref reaches — usually a large `git add` that was never committed.
    /// Removed by `git gc`, never by deleting files: only git knows which are still reachable.
    private func looseObjects(
        in repository: URL,
        gitDirectory: URL,
        ctx: ScanContext
    ) async -> ScanNode? {
        guard let git = await ctx.shell.path(of: "git"),
              let result = try? await ctx.shell.run(
                  executable: git,
                  ["-C", repository.path, "count-objects", "-v"],
                  timeout: .seconds(60)
              ), result.succeeded
        else { return nil }

        var fields: [String: Int64] = [:]
        for line in result.stdout.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            fields[String(parts[0])] = Int64(parts[1].trimmingCharacters(in: .whitespaces))
        }

        // `size` is reported in KiB.
        let looseBytes = (fields["size"] ?? 0) * 1024
        let count = fields["count"] ?? 0
        guard looseBytes >= Self.looseObjectFloor else { return nil }

        // How much of it is actually unreachable — worth knowing before offering to discard it.
        var reachable: Int64 = 0
        if let refs = try? await ctx.shell.run(
            executable: git,
            ["-C", repository.path, "rev-list", "--objects", "--all", "--count"],
            timeout: .seconds(60)
        ), refs.succeeded {
            reachable = Int64(refs.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        }

        let orphaned = max(0, count - reachable)
        let share = count > 0 ? Int(Double(orphaned) / Double(count) * 100) : 0

        return ScanNode(
            id: nodeID("\(Self.identifier(for: repository, home: ctx.home))/loose"),
            title: "Loose objects",
            subtitle: "\(count) objects, \(orphaned) of them reachable from no branch or tag "
                + "(\(share)%) · typically a `git add` that was never committed · "
                + "`git gc --prune=now` discards them permanently",
            url: gitDirectory.appending(path: "objects"),
            size: looseBytes,
            // Moderate rather than safe: gc discards anything unreachable, which includes work
            // that was staged and forgotten but might still be wanted.
            risk: .moderate,
            action: .command(
                executable: git,
                args: ["-C", repository.path, "gc", "--prune=now", "--quiet"],
                displayName: "git gc in \(repository.lastPathComponent)"
            )
        )
    }

    /// Stable node ID from the repository's path.
    static func identifier(for repository: URL, home: URL) -> String {
        let path = repository.path
        let prefix = home.path + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }
}
