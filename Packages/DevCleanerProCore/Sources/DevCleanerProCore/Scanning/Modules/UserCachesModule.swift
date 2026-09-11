import Foundation

/// M7 — `~/Library/Caches`, plus saved application state.
///
/// Folders that belong to another module are skipped outright — not shown greyed with
/// "→ see <Module>" as doc 03 asked for.
///
/// The greyed rows were meant to keep the total honest, but they bought that with a list where
/// the four largest entries were all things you could not act on. An item now appears exactly
/// once, in the module where it can actually be deleted, and this module's total counts only
/// what it can itself remove — which is the number that matters when deciding what to select.
public struct UserCachesModule: ScanModule {
    public init() {}

    public var descriptor: ModuleDescriptor {
        ModuleDescriptor(id: "userCaches", title: "User caches", systemImage: "internaldrive")
    }

    private func cachesRoot(_ ctx: ScanContext) -> URL { ctx.path("Library/Caches") }
    private func savedStateRoot(_ ctx: ScanContext) -> URL {
        ctx.path("Library/Saved Application State")
    }

    public var roots: [AllowedRoot] {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        return [
            // Neither container may be removed itself — only what is inside it.
            AllowedRoot(home.appending(path: "Library/Caches")),
            AllowedRoot(home.appending(path: "Library/Saved Application State"))
        ]
    }

    /// Cache folders owned by another module. Matched by exact name or prefix, because versioned
    /// folders like `ms-playwright-1.4` and `com.anthropic.claudefordesktop.helper` vary.
    private static let ownedElsewhere: [(match: String, isPrefix: Bool, module: String)] = [
        ("com.apple.dt.Xcode", true, "Xcode"),
        ("com.apple.dt.instruments", true, "Xcode"),
        ("JetBrains", false, "JetBrains"),
        ("Google", false, "Android"),
        ("Homebrew", false, "Package caches"),
        ("Yarn", false, "Package caches"),
        ("pip", false, "Package caches"),
        ("pnpm", false, "Package caches"),
        ("CocoaPods", false, "Package caches"),
        ("node-gyp", false, "Package caches"),
        ("ms-playwright", true, "Package caches"),
        ("uv", false, "Package caches"),
        ("go-build", false, "Package caches"),
        ("com.anthropic.claudefordesktop", true, "AI tools"),
        ("com.docker.docker", true, "Docker"),
        ("com.todesktop", true, "AI tools")
    ]

    /// A plain-English note for a cache folder. Recognised families get something specific;
    /// everything else gets the honest generic.
    static func describe(_ name: String) -> String {
        let known: [(String, String)] = [
            ("com.apple.", "Apple system cache — rebuilt automatically"),
            ("com.google.Chrome", "browser cache"),
            ("com.microsoft", "Microsoft app cache"),
            ("Firefox", "browser cache"),
            ("com.spotify", "streaming cache"),
            ("com.tinyspeck", "Slack cache"),
            ("Unity", "Unity editor cache — re-downloaded package and asset data"),
            ("com.unity", "Unity editor cache"),
            ("Raspberry Pi", "downloaded OS images for flashing"),
            ("Cypress", "downloaded test-runner binaries"),
            ("electron", "downloaded Electron binaries"),
            ("com.docker", "Docker Desktop cache"),
            ("Chromium", "browser cache"),
            ("Adobe", "Adobe app cache")
        ]
        for (prefix, note) in known where name.hasPrefix(prefix) || name.contains(prefix) {
            return note
        }
        return "app cache — the app rebuilds it when needed"
    }

    static func owningModule(of folderName: String) -> String? {
        for entry in Self.ownedElsewhere {
            if entry.isPrefix ? folderName.hasPrefix(entry.match) : folderName == entry.match {
                return entry.module
            }
        }
        return nil
    }

    public func scan(_ ctx: ScanContext) async throws -> ScanNode {
        ctx.progress("Measuring ~/Library/Caches")
        var groups: [ScanNode] = []

        if let caches = try await applicationCaches(ctx) { groups.append(caches) }
        if let saved = try await savedApplicationState(ctx) { groups.append(saved) }

        let total = groups.reduce(Int64(0)) { $0 + $1.byteCount }
        return ScanNode(
            id: descriptor.id,
            title: descriptor.title,
            subtitle: "~/Library/Caches",
            url: cachesRoot(ctx),
            size: total,
            risk: .safe,
            children: groups
        )
    }

    // MARK: - Groups

    private func applicationCaches(_ ctx: ScanContext) async throws -> ScanNode? {
        let root = cachesRoot(ctx)
        guard ctx.exists(root) else { return nil }

        let measured = try await ctx.sizer.sizedChildren(of: root)
        guard !measured.isEmpty else { return nil }

        var items: [ScanNode] = []
        var ownTotal: Int64 = 0
        var referredCount = 0
        var protectedCount = 0

        for (url, size) in measured {
            let name = url.lastPathComponent
            let id = nodeID("caches/\(name)")

            // Owned by another module: it is listed there, where it can be deleted.
            if Self.owningModule(of: name) != nil {
                referredCount += 1
                continue
            }

            // A folder that measured nothing but refused to be read is protected rather than
            // empty; saying "0 B" would be a lie.
            if size.bytes == 0, size.unreadableCount > 0 {
                protectedCount += 1
                items.append(ScanNode(
                    id: id,
                    title: name,
                    subtitle: "protected by macOS — size unknown",
                    url: url,
                    size: nil,
                    risk: .info,
                    action: .none
                ))
                continue
            }

            ownTotal += size.bytes
            items.append(ScanNode(
                id: id,
                title: name,
                // Every one of these is one app's scratch space. Saying so on each row is
                // repetitive, but a row with no explanation at all is worse: the user is being
                // asked to delete something identified only by a bundle identifier.
                subtitle: [Self.describe(name), size.unreadableFragment]
                    .compactMap { $0 }.joined(separator: " · "),
                url: url,
                size: size.bytes,
                risk: .safe,
                action: .removePath(url)
            ))
        }

        var subtitleParts = ["~/Library/Caches", "\(items.count) apps"]
        if protectedCount > 0 { subtitleParts.append("\(protectedCount) protected") }
        if referredCount > 0 {
            subtitleParts.append("\(referredCount) shown under their own module instead")
        }

        return ScanNode(
            id: nodeID("caches"),
            title: "Application caches",
            subtitle: subtitleParts.joined(separator: " · "),
            url: root,
            size: ownTotal,
            risk: .safe,
            children: items
        )
    }

    /// Taken from the design, which lists it alongside the caches. Marked `careful` because it
    /// holds reopened windows and unsaved drafts — losing it is not free the way a cache is.
    private func savedApplicationState(_ ctx: ScanContext) async throws -> ScanNode? {
        let root = savedStateRoot(ctx)
        guard ctx.exists(root) else { return nil }

        let measured = try await ctx.sizer.sizedChildren(of: root)
        guard !measured.isEmpty else { return nil }

        let items = measured.map { url, size in
            ScanNode(
                id: nodeID("savedState/\(url.lastPathComponent)"),
                title: url.deletingPathExtension().lastPathComponent,
                subtitle: "windows and unsaved drafts this app would reopen",
                url: url,
                size: size.bytes,
                risk: .careful,
                action: .removePath(url)
            )
        }

        return ScanNode(
            id: nodeID("savedState"),
            title: "Saved application state",
            subtitle: "reopened windows & unsaved drafts · \(items.count) apps",
            url: root,
            size: measured.reduce(Int64(0)) { $0 + $1.size.bytes },
            risk: .careful,
            children: items
        )
    }
}
