import Foundation

/// M1 — Xcode's build products, archives, device support and caches.
///
/// Usually the largest single module on a developer's Mac, and DerivedData is usually most of
/// it. Note that `Archives` is `careful` rather than a cache: an `.xcarchive` holds the dSYMs
/// needed to symbolise crash reports from a build that has already shipped, and once it is gone
/// those crash reports stay unreadable forever.
public struct XcodeModule: ScanModule {
    public init() {}

    public var descriptor: ModuleDescriptor {
        ModuleDescriptor(id: "xcode", title: "Xcode", systemImage: "hammer")
    }

    public var roots: [AllowedRoot] {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        func dev(_ p: String) -> URL { home.appending(path: "Library/Developer/\(p)") }
        return [
            // Containers: only their contents may go, so a stray bug cannot remove the
            // directory Xcode expects to find.
            AllowedRoot(dev("Xcode/DerivedData")),
            AllowedRoot(dev("Xcode/Archives")),
            AllowedRoot(dev("Xcode/iOS DeviceSupport")),
            AllowedRoot(dev("Xcode/watchOS DeviceSupport")),
            AllowedRoot(dev("Xcode/tvOS DeviceSupport")),
            AllowedRoot(dev("Xcode/visionOS DeviceSupport")),
            // Pure caches Xcode recreates on demand, so these may go whole.
            AllowedRoot(dev("Xcode/UserData/Previews"), deletableItself: true),
            AllowedRoot(dev("Xcode/Products"), deletableItself: true),
            AllowedRoot(dev("Xcode/Index"), deletableItself: true),
            AllowedRoot(dev("Xcode/Caches"), deletableItself: true),
            AllowedRoot(dev("Shared/Documentation/DocSets")),
            AllowedRoot(home.appending(path: "Library/Caches/com.apple.dt.Xcode"),
                        deletableItself: true)
        ]
    }

    public func isAvailable(_ ctx: ScanContext) async -> Bool {
        ctx.exists(ctx.path("Library/Developer/Xcode"))
    }

    // MARK: - Scan

    public func scan(_ ctx: ScanContext) async throws -> ScanNode {
        var groups: [ScanNode] = []

        if let node = try await derivedData(ctx) { groups.append(node) }
        if let node = try await archives(ctx) { groups.append(node) }
        if let node = try await deviceSupport(ctx) { groups.append(node) }
        if let node = try await caches(ctx) { groups.append(node) }
        if let node = try await simpleFolders(ctx) { groups.append(node) }
        if let node = try await docSets(ctx) { groups.append(node) }

        return ScanNode(
            id: descriptor.id,
            title: descriptor.title,
            subtitle: "~/Library/Developer/Xcode",
            url: ctx.path("Library/Developer/Xcode"),
            size: groups.reduce(Int64(0)) { $0 + $1.byteCount },
            risk: .moderate,
            children: groups
        )
    }

    /// Xcode appends `-<22-char hash>` to each project's DerivedData folder. Stripping it gives a
    /// name the user recognises; keeping it would make six similar rows unreadable.
    static func projectName(from folderName: String) -> String {
        guard let dash = folderName.lastIndex(of: "-") else { return folderName }
        let suffix = folderName[folderName.index(after: dash)...]
        let looksLikeHash = suffix.count >= 20 && suffix.allSatisfy(\.isLetter)
        return looksLikeHash ? String(folderName[..<dash]) : folderName
    }

    /// Shared caches that sit beside the per-project folders and are not projects.
    private static let derivedDataSharedFolders: Set<String> = [
        "ModuleCache.noindex", "SDKStatCaches.noindex", "SymbolCache.noindex",
        "EagerLinkingTBDs", "Manifests.noindex", "IDEDependenciesCache.noindex"
    ]

    private func derivedData(_ ctx: ScanContext) async throws -> ScanNode? {
        let root = ctx.path("Library/Developer/Xcode/DerivedData")
        guard ctx.exists(root) else { return nil }
        ctx.progress("Measuring DerivedData")

        let measured = try await ctx.sizer.sizedChildren(of: root)
        guard !measured.isEmpty else { return nil }

        var projects: [ScanNode] = []
        var shared: [ScanNode] = []

        for (url, size) in measured {
            let name = url.lastPathComponent
            let isShared = Self.derivedDataSharedFolders.contains(name)
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate

            let node = ScanNode(
                id: nodeID("derived/\(name)"),
                title: isShared ? name : Self.projectName(from: name),
                subtitle: isShared
                    ? "shared build cache"
                    : modified.map { "last used \(Self.dateText($0))" },
                url: url,
                size: size.bytes,
                risk: .moderate,
                action: .removePath(url)
            )
            if isShared { shared.append(node) } else { projects.append(node) }
        }

        let children = projects + shared
        return ScanNode(
            id: nodeID("derived"),
            title: "Derived Data",
            subtitle: "\(projects.count) project\(projects.count == 1 ? "" : "s")"
                + " · rebuilt on next build",
            url: root,
            size: measured.reduce(Int64(0)) { $0 + $1.size.bytes },
            risk: .moderate,
            children: children
        )
    }

    private func archives(_ ctx: ScanContext) async throws -> ScanNode? {
        let root = ctx.path("Library/Developer/Xcode/Archives")
        guard ctx.exists(root) else { return nil }
        ctx.progress("Measuring Archives")

        // Archives nest by date folder, then by .xcarchive. Grouping by app name instead of by
        // date is what the design shows, and it is the more useful axis: the question is "do I
        // still need archives for this app", not "what did I build in March".
        var byApp: [String: [ScanNode]] = [:]
        var total: Int64 = 0

        for dateFolder in try ctx.sizer.directChildren(of: root) {
            for archive in try ctx.sizer.directChildren(of: dateFolder)
            where archive.pathExtension == "xcarchive" {
                let size = try await ctx.sizer.size(of: archive)
                total += size.bytes
                let stem = archive.deletingPathExtension().lastPathComponent
                // "Aurora 2026-08-14 09.12" → "Aurora"
                let app = stem.split(separator: " ").first.map(String.init) ?? stem
                byApp[app, default: []].append(ScanNode(
                    id: nodeID("archives/\(dateFolder.lastPathComponent)/\(archive.lastPathComponent)"),
                    title: stem,
                    subtitle: "contains dSYMs for symbolising crash reports",
                    url: archive,
                    size: size.bytes,
                    risk: .careful,
                    action: .removePath(archive)
                ))
            }
        }
        guard !byApp.isEmpty else { return nil }

        let appNodes = byApp.map { app, archives in
            ScanNode(
                id: nodeID("archives/app/\(app)"),
                title: app,
                subtitle: "\(archives.count) archive\(archives.count == 1 ? "" : "s")",
                size: archives.reduce(Int64(0)) { $0 + $1.byteCount },
                risk: .careful,
                children: archives
            )
        }

        let count = byApp.values.reduce(0) { $0 + $1.count }
        return ScanNode(
            id: nodeID("archives"),
            title: "Archives",
            subtitle: "\(count) archive\(count == 1 ? "" : "s") · dSYMs for shipped builds",
            url: root,
            size: total,
            risk: .careful,
            children: appNodes
        )
    }

    private static let deviceSupportPlatforms = ["iOS", "watchOS", "tvOS", "visionOS"]

    private func deviceSupport(_ ctx: ScanContext) async throws -> ScanNode? {
        ctx.progress("Measuring device support")
        struct Entry {
            let platform: String
            let url: URL
            let bytes: Int64
        }
        var entries: [Entry] = []

        for platform in Self.deviceSupportPlatforms {
            let root = ctx.path("Library/Developer/Xcode/\(platform) DeviceSupport")
            guard ctx.exists(root) else { continue }
            for (url, size) in try await ctx.sizer.sizedChildren(of: root) {
                entries.append(Entry(platform: platform, url: url, bytes: size.bytes))
            }
        }
        guard !entries.isEmpty else { return nil }

        // Doc 03: the newest version per platform is worth keeping, older ones are safe. The
        // newest gets recreated the moment the device is plugged in again, but that costs several
        // minutes of waiting, which is not the same as free.
        let newest = VersionCompare.highestPerGroup(
            entries,
            id: { $0.url.path },
            group: \.platform,
            version: { $0.url.lastPathComponent }
        )

        var byPlatform: [String: [ScanNode]] = [:]
        for entry in entries {
            let isNewest = newest.contains(entry.url.path)
            byPlatform[entry.platform, default: []].append(ScanNode(
                id: nodeID("deviceSupport/\(entry.platform)/\(entry.url.lastPathComponent)"),
                title: entry.url.lastPathComponent,
                subtitle: isNewest
                    ? "newest — re-created slowly on next attach"
                    : "debug symbols for a device you no longer use",
                url: entry.url,
                size: entry.bytes,
                risk: isNewest ? .moderate : .safe,
                action: .removePath(entry.url)
            ))
        }

        let platformNodes = Self.deviceSupportPlatforms.compactMap { platform -> ScanNode? in
            guard let children = byPlatform[platform] else { return nil }
            return ScanNode(
                id: nodeID("deviceSupport/\(platform)"),
                title: "\(platform) DeviceSupport",
                subtitle: "\(children.count) version\(children.count == 1 ? "" : "s")",
                url: ctx.path("Library/Developer/Xcode/\(platform) DeviceSupport"),
                size: children.reduce(Int64(0)) { $0 + $1.byteCount },
                risk: .safe,
                children: children
            )
        }

        return ScanNode(
            id: nodeID("deviceSupport"),
            title: "Device Support",
            subtitle: "symbols for attached devices",
            size: platformNodes.reduce(Int64(0)) { $0 + $1.byteCount },
            risk: .safe,
            children: platformNodes
        )
    }

    private func caches(_ ctx: ScanContext) async throws -> ScanNode? {
        ctx.progress("Measuring Xcode caches")
        // Two separate locations, both pure cache, presented as one group because the
        // distinction means nothing to the user.
        let candidates: [(title: String, url: URL, subtitle: String?)] = [
            ("Xcode application cache", ctx.path("Library/Caches/com.apple.dt.Xcode"),
             "~/Library/Caches/com.apple.dt.Xcode"),
            ("Xcode build caches", ctx.path("Library/Developer/Xcode/Caches"),
             "~/Library/Developer/Xcode/Caches")
        ]

        var children: [ScanNode] = []
        for candidate in candidates {
            guard ctx.exists(candidate.url) else { continue }
            let size = try await ctx.sizer.size(of: candidate.url)
            guard size.bytes > 0 else { continue }
            children.append(ScanNode(
                id: nodeID("caches/\(candidate.url.lastPathComponent)"),
                title: candidate.title,
                subtitle: candidate.subtitle,
                url: candidate.url,
                size: size.bytes,
                risk: .safe,
                action: .removePath(candidate.url)
            ))
        }
        guard !children.isEmpty else { return nil }

        return ScanNode(
            id: nodeID("caches"),
            title: "Caches",
            subtitle: "pure cache — Xcode recreates all of it on demand",
            size: children.reduce(Int64(0)) { $0 + $1.byteCount },
            risk: .safe,
            children: children
        )
    }

    /// Previews, Products and Index — flat, safe, and only shown when they hold something.
    private func simpleFolders(_ ctx: ScanContext) async throws -> ScanNode? {
        let candidates: [(String, String, Risk)] = [
            ("Previews", "Xcode/UserData/Previews", .safe),
            ("Products", "Xcode/Products", .safe),
            ("Index", "Xcode/Index", .safe)
        ]
        var children: [ScanNode] = []
        for (title, relative, risk) in candidates {
            let url = ctx.path("Library/Developer/\(relative)")
            guard ctx.exists(url) else { continue }
            let size = try await ctx.sizer.size(of: url)
            guard size.bytes > 0 else { continue }
            children.append(ScanNode(
                id: nodeID("simple/\(title)"),
                title: title,
                subtitle: "~/Library/Developer/\(relative)",
                url: url,
                size: size.bytes,
                risk: risk,
                action: .removePath(url)
            ))
        }
        guard !children.isEmpty else { return nil }

        return ScanNode(
            id: nodeID("simple"),
            title: "Build products & index",
            subtitle: "regenerated by the next build",
            size: children.reduce(Int64(0)) { $0 + $1.byteCount },
            risk: .safe,
            children: children
        )
    }

    private func docSets(_ ctx: ScanContext) async throws -> ScanNode? {
        let root = ctx.path("Library/Developer/Shared/Documentation/DocSets")
        guard ctx.exists(root) else { return nil }
        let size = try await ctx.sizer.size(of: root)
        guard size.bytes > 0 else { return nil }
        return ScanNode(
            id: nodeID("docsets"),
            title: "Documentation sets",
            subtitle: "re-downloaded by Xcode when needed",
            url: root,
            size: size.bytes,
            risk: .moderate,
            action: .removePath(root)
        )
    }

    // MARK: - Pre-delete

    /// Doc 03 poses the question and answers itself: block rather than warn. Xcode holds open
    /// file handles into DerivedData, and pulling it out mid-build produces failures that look
    /// like compiler bugs.
    public func preDeleteCheck(_ node: ScanNode, _ ctx: ScanContext) async -> String? {
        guard node.id.hasPrefix(nodeID("derived")) else { return nil }
        let processes = ProcessCheck(shell: ctx.shell)
        guard await processes.isRunning(pattern: "MacOS/Xcode|xcodebuild") else { return nil }
        return "Quit Xcode first — it has files open in Derived Data."
    }

    // MARK: - Helpers

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d yyyy"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static func dateText(_ date: Date) -> String {
        dateFormatter.string(from: date)
    }
}
