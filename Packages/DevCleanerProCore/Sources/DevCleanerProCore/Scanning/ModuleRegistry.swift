import Foundation

/// The one place modules are listed. Order here is sidebar order, which doc 03 sets by typical
/// size impact — biggest wins first.
public enum ModuleRegistry {
    /// Every module the app knows about, enabled or not.
    ///
    /// Custom locations is last and takes the user's configured folders, so it is built from the
    /// config rather than being a plain value like the others.
    public static func allModules(config: UserConfig) -> [any ScanModule] {
        // Order here is both sidebar order and the order scans are started in, so it runs
        // roughly cheapest first: a module that answers in under a second should not be sitting
        // behind one that walks a million files. Doc 03 ordered by typical size impact instead,
        // which meant the two slowest modules started first and nothing appeared for half a
        // minute.
        [
            LogsModule(),               // one directory, a handful of children
            BackupsModule(),            // two lookups and one tmutil call
            DockerModule(),             // a few CLI calls, or a fast failure if the daemon is off
            ContainerRuntimesModule(),  // a handful of paths, usually absent
            SimulatorsModule(),         // two simctl calls plus a shallow asset scan
            AIToolsModule(),            // a dozen shallow directories
            JetBrainsModule(),          // three directories, one level each
            XcodeModule(),              // large but shallow
            GitRepositoriesModule(),    // walks the code folders, but only three levels
            AndroidModule(),
            UserCachesModule(),
            CustomLocationsModule(customRoots: config.customRoots),
            ProjectArtifactsModule(),   // walks every project five levels deep
            PackageCachesModule()       // ~/.cocoapods/repos alone is 1.8 million files
        ]
    }

    /// Modules the user has not disabled and whose tool and roots are actually present.
    ///
    /// Availability is checked **concurrently**. Serially this was the reason nothing appeared
    /// for the first several seconds: fourteen modules, two of which walk a thousand directories
    /// looking for git repositories and one of which waits on a login shell, all before the
    /// first scan could start.
    public static func activeModules(ctx: ScanContext) async -> [any ScanModule] {
        let candidates = allModules(config: ctx.config)
            .filter { ctx.config.isEnabled($0.descriptor.id) }

        let availability = await withTaskGroup(
            of: (Int, Bool).self, returning: [Int: Bool].self
        ) { group in
            for (index, module) in candidates.enumerated() {
                group.addTask { (index, await module.isAvailable(ctx)) }
            }
            var result: [Int: Bool] = [:]
            for await answer in group { result[answer.0] = answer.1 }
            return result
        }

        return candidates.enumerated()
            .filter { availability[$0.offset] == true }
            .map(\.element)
    }

    /// The allowlist handed to `PathGuard`: every root every module declares, plus the user's
    /// custom locations. Built from the modules themselves, so a module cannot delete outside
    /// what it declared.
    public static func allowedRoots(config: UserConfig) -> [AllowedRoot] {
        deduplicated(allModules(config: config).flatMap(\.roots))
    }

    /// Collapses roots that resolve to the same directory.
    ///
    /// Two modules can legitimately claim one path — `~/Library/Caches/ms-playwright` is both a
    /// package cache and, on this machine, a custom location. Left as duplicates with different
    /// `deletableItself` flags, `PathGuard` picks between them by path length, which is a tie,
    /// so which one wins is undefined. `deletableItself` is OR-ed: if any module means to remove
    /// that directory whole, it must be able to, and a module that only ever addresses the
    /// contents is unaffected either way.
    static func deduplicated(_ roots: [AllowedRoot]) -> [AllowedRoot] {
        var byPath: [String: Bool] = [:]
        var order: [String] = []
        for root in roots {
            if byPath[root.url.path] == nil { order.append(root.url.path) }
            byPath[root.url.path] = (byPath[root.url.path] ?? false) || root.deletableItself
        }
        return order.map { AllowedRoot(URL(fileURLWithPath: $0),
                                       deletableItself: byPath[$0] ?? false) }
    }
}
