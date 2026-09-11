import Foundation

/// M5 — JetBrains IDE caches, settings and logs.
///
/// The same `<Product><YYYY.N>` folder appears in three places — Caches, Application Support and
/// Logs — so the tree merges them into one row per version. That is the shape a user thinks in
/// ("I no longer have WebStorm 2026.1 installed"), and it means one checkbox removes all three
/// rather than leaving two of them behind.
///
/// One trap worth knowing: `local-history` inside Application Support is not a cache. It holds
/// JetBrains' own record of uncommitted edits, which is sometimes the only copy of work that was
/// never committed — so it is `careful` while everything around it is `safe`.
public struct JetBrainsModule: ScanModule {
    public init() {}

    public var descriptor: ModuleDescriptor {
        ModuleDescriptor(id: "jetbrains", title: "JetBrains", systemImage: "curlybraces.square")
    }

    private static let areas: [(key: String, relative: String, label: String)] = [
        ("caches", "Library/Caches/JetBrains", "Caches"),
        ("support", "Library/Application Support/JetBrains", "Settings & plugins"),
        ("logs", "Library/Logs/JetBrains", "Logs")
    ]

    public var roots: [AllowedRoot] {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        return Self.areas.map { AllowedRoot(home.appending(path: $0.relative)) }
    }

    public func isAvailable(_ ctx: ScanContext) async -> Bool {
        ctx.anyExists(Self.areas.map { ctx.path($0.relative) })
    }

    /// Splits `WebStorm2026.2` into ("WebStorm", "2026.2").
    ///
    /// Anything that does not match — `Toolbox`, `Daemon`, `acp-agents`, `consentOptions` — is
    /// deliberately not a product version and is handled separately.
    static func splitProductVersion(_ folder: String) -> (product: String, version: String)? {
        guard let match = folder.wholeMatch(of: /([A-Za-z ]+?)(\d{4}\.\d+)/) else { return nil }
        return (String(match.1), String(match.2))
    }

    public func scan(_ ctx: ScanContext) async throws -> ScanNode {
        ctx.progress("Measuring JetBrains IDEs")

        /// area key → folder name → (url, bytes)
        var byArea: [String: [String: (url: URL, bytes: Int64)]] = [:]
        for area in Self.areas {
            let root = ctx.path(area.relative)
            guard ctx.exists(root) else { continue }
            var found: [String: (url: URL, bytes: Int64)] = [:]
            for (url, size) in try await ctx.sizer.sizedChildren(of: root) {
                found[url.lastPathComponent] = (url, size.bytes)
            }
            byArea[area.key] = found
        }

        // Every versioned folder seen in any of the three areas.
        var versionsByProduct: [String: Set<String>] = [:]
        var nonProductFolders: Set<String> = []
        for folders in byArea.values {
            for name in folders.keys {
                if let split = Self.splitProductVersion(name) {
                    versionsByProduct[split.product, default: []].insert(split.version)
                } else {
                    nonProductFolders.insert(name)
                }
            }
        }

        var groups: [ScanNode] = []
        if let node = productsGroup(ctx, byArea: byArea, versionsByProduct: versionsByProduct) {
            groups.append(node)
        }
        if let node = sharedGroup(ctx, byArea: byArea, folders: nonProductFolders) {
            groups.append(node)
        }

        return ScanNode(
            id: descriptor.id,
            title: descriptor.title,
            subtitle: "caches, settings and logs merged per IDE version",
            url: ctx.path("Library/Caches/JetBrains"),
            size: groups.reduce(Int64(0)) { $0 + $1.byteCount },
            risk: .safe,
            children: groups
        )
    }

    // MARK: - Products

    private func productsGroup(
        _ ctx: ScanContext,
        byArea: [String: [String: (url: URL, bytes: Int64)]],
        versionsByProduct: [String: Set<String>]
    ) -> ScanNode? {
        guard !versionsByProduct.isEmpty else { return nil }
        var productNodes: [ScanNode] = []

        for (product, versions) in versionsByProduct {
            let newest = VersionCompare.highest(Array(versions))
            var versionNodes: [ScanNode] = []

            for version in versions {
                let folder = "\(product)\(version)"
                let isNewest = version == newest
                var parts: [ScanNode] = []
                var paths: [URL] = []

                for area in Self.areas {
                    guard let entry = byArea[area.key]?[folder] else { continue }
                    paths.append(entry.url)
                    parts.append(contentsOf: areaNodes(
                        ctx,
                        area: area,
                        folder: folder,
                        entry: entry,
                        isNewest: isNewest
                    ))
                }
                guard !parts.isEmpty else { continue }

                versionNodes.append(ScanNode(
                    id: nodeID("product/\(product)/\(version)"),
                    title: "\(product) \(version)",
                    subtitle: isNewest
                        ? "newest installed version"
                        : "old version — safe once the IDE is gone",
                    size: parts.reduce(Int64(0)) { $0 + $1.byteCount },
                    // Careful when it is the newest — that takes settings and plugins with it —
                    // and also whenever local history turned up underneath, since removing the
                    // whole version removes that too.
                    risk: isNewest || parts.contains { $0.risk == .careful } ? .careful : .safe,
                    action: .removePaths(paths),
                    children: parts
                ))
            }
            guard !versionNodes.isEmpty else { continue }

            productNodes.append(ScanNode(
                id: nodeID("product/\(product)"),
                title: product,
                subtitle: "\(versionNodes.count) version\(versionNodes.count == 1 ? "" : "s")"
                    + " · caches, settings and logs merged per version",
                size: versionNodes.reduce(Int64(0)) { $0 + $1.byteCount },
                risk: .safe,
                children: versionNodes
            ))
        }
        guard !productNodes.isEmpty else { return nil }

        return ScanNode(
            id: nodeID("products"),
            title: "IDEs",
            subtitle: "one row per installed IDE, with its versions underneath",
            size: productNodes.reduce(Int64(0)) { $0 + $1.byteCount },
            risk: .safe,
            children: productNodes
        )
    }

    /// Subdirectories that are not caches even though they sit inside one.
    ///
    /// `LocalHistory` is JetBrains' record of every edit made outside version control, and it is
    /// sometimes the only copy of work that was never committed. On 2026-era releases it lives
    /// under **Caches**, not Application Support — the opposite of what the design assumed —
    /// which means treating the whole Caches folder as `safe` would quietly offer to delete
    /// uncommitted work. Both spellings are checked because older releases used the hyphenated
    /// name under Application Support.
    private static let sensitiveSubfolders: [(name: String, title: String, note: String)] = [
        ("LocalHistory", "Local history",
         "every edit made outside version control — sometimes the only copy"),
        ("local-history", "Local history",
         "every edit made outside version control — sometimes the only copy")
    ]

    /// The per-area rows under a version, with anything that is not really a cache pulled out
    /// into its own `careful` row and subtracted from the row it came from.
    private func areaNodes(
        _ ctx: ScanContext,
        area: (key: String, relative: String, label: String),
        folder: String,
        entry: (url: URL, bytes: Int64),
        isNewest: Bool
    ) -> [ScanNode] {
        let baseID = nodeID("area/\(area.key)/\(folder)")

        // Losing the newest version's settings and plugins is a real loss, not a rebuild.
        let areaRisk: Risk = area.key == "support" && isNewest ? .careful : .safe
        let areaSubtitle: String? = switch area.key {
        case "caches": "indexes and build output — rebuilt on next open"
        case "support": "settings, keymaps and installed plugins"
        case "logs": "diagnostic logs — safe to remove at any time"
        default: nil
        }

        var extracted: [ScanNode] = []
        var deducted: Int64 = 0

        for sensitive in Self.sensitiveSubfolders {
            let url = entry.url.appending(path: sensitive.name)
            guard ctx.exists(url),
                  let bytes = try? FileManager.default.allocatedSize(of: url),
                  bytes > 0
            else { continue }
            deducted += bytes
            extracted.append(ScanNode(
                id: nodeID("area/\(area.key)/\(folder)/\(sensitive.name)"),
                title: sensitive.title,
                subtitle: sensitive.note,
                url: url,
                size: bytes,
                risk: .careful,
                action: .removePath(url)
            ))
        }

        let areaNode = ScanNode(
            id: baseID,
            title: area.label,
            subtitle: areaSubtitle,
            url: entry.url,
            // The remainder, so the version total is not counted twice.
            size: max(0, entry.bytes - deducted),
            risk: areaRisk,
            action: .removePath(entry.url)
        )
        return [areaNode] + extracted
    }

    // MARK: - Shared, non-versioned folders

    /// Toolbox, the shared daemon, agent caches and so on.
    private func sharedGroup(
        _ ctx: ScanContext,
        byArea: [String: [String: (url: URL, bytes: Int64)]],
        folders: Set<String>
    ) -> ScanNode? {
        var children: [ScanNode] = []

        for area in Self.areas {
            guard let entries = byArea[area.key] else { continue }
            for folder in folders.sorted() {
                guard let entry = entries[folder], entry.bytes > 0 else { continue }

                // Toolbox's Application Support directory is how Toolbox knows which IDEs it
                // installed; removing it makes it forget them. Its cache is fair game.
                let isToolboxState = folder == "Toolbox" && area.key == "support"
                children.append(ScanNode(
                    id: nodeID("shared/\(area.key)/\(folder)"),
                    title: "\(folder) — \(area.label)",
                    subtitle: isToolboxState
                        ? "Toolbox's record of installed IDEs — removing it makes it forget them"
                        : Self.describeShared(folder, area: area.key),
                    url: entry.url,
                    size: entry.bytes,
                    risk: isToolboxState ? .info : .safe,
                    action: isToolboxState ? .none : .removePath(entry.url),
                    isAdvisory: isToolboxState
                ))
            }
        }
        guard !children.isEmpty else { return nil }

        return ScanNode(
            id: nodeID("shared"),
            title: "Shared",
            subtitle: "Toolbox, daemons and agent caches",
            size: children.reduce(Int64(0)) { $0 + $1.byteCount },
            risk: .safe,
            children: children
        )
    }

    /// Shared JetBrains folders are not tied to one IDE, so each needs its own note.
    static func describeShared(_ folder: String, area: String) -> String {
        let what: String = switch folder {
        case "Toolbox", "Toolbox-Dev": "JetBrains Toolbox"
        case "Daemon": "the shared background daemon"
        case "acp-agents": "AI agent support"
        case "IntelliJ": "shared IntelliJ platform data"
        case "bl", "crl", "discovery", "consentOptions", "PrivacyPolicy":
            "licensing and consent bookkeeping"
        case "Local": "shared local state"
        default: folder
        }
        return switch area {
        case "caches": "\(what) — cache, rebuilt on demand"
        case "logs": "\(what) — diagnostic logs"
        default: "\(what) — settings and state"
        }
    }

    // MARK: - Pre-delete

    /// Blocks only the product actually running, so one open IDE does not lock the other four.
    public func preDeleteCheck(_ node: ScanNode, _ ctx: ScanContext) async -> String? {
        let processes = ProcessCheck(shell: ctx.shell)
        let running = await processes.runningNames(
            pattern: "JetBrains|WebStorm|Rider|PyCharm|DataGrip|IntelliJ|GoLand|CLion|RubyMine|PhpStorm"
        )
        guard !running.isEmpty else { return nil }

        for name in Set(running) where node.id.localizedCaseInsensitiveContains(name) {
            return "Quit \(name) first — it has these files open"
        }
        return nil
    }
}

private extension FileManager {
    /// Small synchronous helper for the one place a nested size is needed inline.
    func allocatedSize(of url: URL) throws -> Int64 {
        var total: Int64 = 0
        guard let enumerator = enumerator(
            at: url,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey],
            options: [],
            errorHandler: { _, _ in true }
        ) else { return 0 }
        for case let child as URL in enumerator {
            let values = try? child.resourceValues(
                forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
            )
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
        }
        return total
    }
}
