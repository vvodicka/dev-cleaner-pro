import Foundation

/// M2 — simulator runtimes, devices, and the stored runtime images behind them.
///
/// The module that pays for the whole app on a machine with a few years of Xcode upgrades
/// behind it. Three things make it delicate:
///
/// 1. **`/Library/Developer/CoreSimulator/Volumes` must never be measured.** Those are mount
///    points for the runtime images. `du -sh /Library/Developer/CoreSimulator` counts the same
///    bytes twice because of them, which is why that number looks impossibly large.
/// 2. **Orphan detection has to distinguish two storage layouts.** Only "Patchable Cryptex Disk
///    Image" runtimes live in `/System/Library/AssetsV2`; older ones live under
///    `/Library/Developer/CoreSimulator/Cryptex`. Treating one layout as the only one would
///    report live runtimes as orphans.
/// 3. **Neither store is user-writable**, so orphans are info rows with copyable commands, never
///    checkboxes. `AssetsV2` additionally carries the SIP `restricted` flag, so not even `sudo`
///    can remove it — that needs Recovery mode, and the row says so.
public struct SimulatorsModule: ScanModule {
    public init() {}

    public var descriptor: ModuleDescriptor {
        ModuleDescriptor(
            id: "simulators",
            title: "Simulators",
            systemImage: "iphone",
            requiresTool: "xcrun"
        )
    }

    public var roots: [AllowedRoot] {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        return [
            // Devices are removed through simctl, not by path, but the caches are ours.
            AllowedRoot(home.appending(path: "Library/Developer/CoreSimulator/Caches"),
                        deletableItself: true),
            AllowedRoot(home.appending(path: "Library/Logs/CoreSimulator"))
        ]
        // Deliberately absent: /Library/Developer/CoreSimulator and /System/Library/AssetsV2.
        // Both are measured, neither is ever deletable by this app.
    }

    public func isAvailable(_ ctx: ScanContext) async -> Bool {
        await ctx.shell.has("xcrun")
            && ctx.exists(ctx.path("Library/Developer/CoreSimulator"))
    }

    // MARK: - Scan

    public func scan(_ ctx: ScanContext) async throws -> ScanNode {
        ctx.progress("Listing simulator runtimes")
        let runtimes = try await loadRuntimes(ctx)
        let devicesByRuntime = try await loadDevices(ctx)

        var groups: [ScanNode] = []
        if let node = runtimesGroup(runtimes, devices: devicesByRuntime) { groups.append(node) }
        if let node = devicesGroup(devicesByRuntime, runtimes: runtimes) { groups.append(node) }
        if let node = try await cachesGroup(ctx) { groups.append(node) }
        if let node = try await unreachableGroup(ctx, runtimes: runtimes) { groups.append(node) }
        groups.append(maintenanceGroup(ctx))

        return ScanNode(
            id: descriptor.id,
            title: descriptor.title,
            subtitle: "\(runtimes.count) runtime\(runtimes.count == 1 ? "" : "s") · "
                + "\(devicesByRuntime.values.reduce(0) { $0 + $1.count }) devices",
            url: ctx.path("Library/Developer/CoreSimulator"),
            size: groups.reduce(Int64(0)) { $0 + $1.byteCount },
            risk: .moderate,
            children: groups
        )
    }

    private func loadRuntimes(_ ctx: ScanContext) async throws -> [SimRuntime] {
        let result = try await ctx.shell.run(
            tool: "xcrun", ["simctl", "runtime", "list", "-j"], timeout: .seconds(60)
        )
        guard result.succeeded else {
            throw ScanFailure(message: "xcrun simctl runtime list failed: \(result.failureMessage)")
        }
        return try SimulatorParsing.runtimes(fromRuntimeListJSON: Data(result.stdout.utf8))
    }

    private func loadDevices(_ ctx: ScanContext) async throws -> [String: [SimDevice]] {
        let result = try await ctx.shell.run(
            tool: "xcrun", ["simctl", "list", "devices", "-j"], timeout: .seconds(60)
        )
        guard result.succeeded else {
            throw ScanFailure(message: "xcrun simctl list devices failed: \(result.failureMessage)")
        }
        return try SimulatorParsing.devices(fromDeviceListJSON: Data(result.stdout.utf8))
    }

    // MARK: - Runtimes

    private func runtimesGroup(
        _ runtimes: [SimRuntime],
        devices: [String: [SimDevice]]
    ) -> ScanNode? {
        guard !runtimes.isEmpty else { return nil }

        // The newest build per platform is what Xcode will reach for next, so removing it costs
        // a multi-gigabyte re-download. Older ones are a re-download the user chose to keep.
        let newest = VersionCompare.highestPerGroup(
            runtimes, id: \.identifier, group: \.platform, version: \.shortVersion
        )

        let children = runtimes.map { runtime -> ScanNode in
            let attached = devices[runtime.runtimeIdentifier] ?? []
            let booted = attached.filter(\.isBooted)
            let isNewest = newest.contains(runtime.identifier)

            var parts: [String] = []
            if let last = runtime.lastUsedDate {
                parts.append("last used \(XcodeModule.dateText(last))")
            } else {
                parts.append("never used")
            }
            if !attached.isEmpty {
                parts.append("\(attached.count) device\(attached.count == 1 ? "" : "s")")
            }
            if isNewest { parts.append("newest \(runtime.platform)") }
            if !runtime.isReady { parts.append("state: \(runtime.state)") }

            return ScanNode(
                id: nodeID("runtime/\(runtime.identifier)"),
                title: runtime.displayName,
                subtitle: parts.joined(separator: " · "),
                size: runtime.sizeBytes,
                risk: isNewest ? .careful : .moderate,
                action: runtime.deletable
                    ? .command(
                        executable: "/usr/bin/xcrun",
                        args: ["simctl", "runtime", "delete", runtime.identifier],
                        displayName: "Delete \(runtime.displayName)"
                    )
                    : .none,
                blockedReason: booted.isEmpty
                    ? nil
                    : "\(booted[0].name) is booted on this runtime — shut it down first"
            )
        }

        return ScanNode(
            id: nodeID("runtimes"),
            title: "Runtimes",
            subtitle: "downloadable again from Xcode",
            size: runtimes.reduce(Int64(0)) { $0 + ($1.sizeBytes ?? 0) },
            risk: .moderate,
            children: children
        )
    }

    // MARK: - Devices

    private func devicesGroup(
        _ byRuntime: [String: [SimDevice]],
        runtimes: [SimRuntime]
    ) -> ScanNode? {
        guard !byRuntime.isEmpty else { return nil }

        // A friendly name per runtime identifier. Two runtimes can share one identifier, so the
        // shortest display name wins rather than an arbitrary one.
        var names: [String: String] = [:]
        for runtime in runtimes {
            let existing = names[runtime.runtimeIdentifier]
            let candidate = "\(runtime.platform) \(runtime.shortVersion)"
            if existing == nil || candidate.count < existing!.count {
                names[runtime.runtimeIdentifier] = candidate
            }
        }

        var runtimeNodes: [ScanNode] = []
        var unavailable: [ScanNode] = []

        for (runtimeID, devices) in byRuntime {
            let usable = devices.filter(\.isUsable)
            let unusable = devices.filter { !$0.isUsable }

            unavailable += unusable.map { device in
                ScanNode(
                    id: nodeID("device/\(device.udid)"),
                    title: device.name,
                    subtitle: device.availabilityError
                        ?? "runtime not installed — cannot boot",
                    url: device.dataPath.map { URL(fileURLWithPath: $0) },
                    size: device.totalBytes,
                    risk: .safe,
                    // Handled as a set by the group's own action, so the row itself is
                    // informational: deleting them one at a time would run simctl N times.
                    action: .none
                )
            }

            guard !usable.isEmpty else { continue }
            let children = usable.map { device -> ScanNode in
                var parts: [String] = [device.state]
                if let booted = device.lastBootedDate {
                    parts.append("last booted \(XcodeModule.dateText(booted))")
                }
                return ScanNode(
                    id: nodeID("device/\(device.udid)"),
                    title: device.name,
                    subtitle: parts.joined(separator: " · "),
                    url: device.dataPath.map { URL(fileURLWithPath: $0) },
                    size: device.totalBytes,
                    // Careful because a simulator holds app data, databases and signed-in
                    // sessions the user may be mid-way through testing against.
                    risk: .careful,
                    action: .command(
                        executable: "/usr/bin/xcrun",
                        args: ["simctl", "delete", device.udid],
                        displayName: "Delete \(device.name)"
                    ),
                    blockedReason: device.isBooted
                        ? "Simulator is booted — shut it down to delete"
                        : nil
                )
            }

            runtimeNodes.append(ScanNode(
                id: nodeID("devices/\(runtimeID)"),
                title: names[runtimeID] ?? runtimeID,
                subtitle: "\(children.count) device\(children.count == 1 ? "" : "s")",
                size: children.reduce(Int64(0)) { $0 + $1.byteCount },
                risk: .careful,
                children: children
            ))
        }

        if !unavailable.isEmpty {
            runtimeNodes.append(ScanNode(
                id: nodeID("devices/unavailable"),
                title: "Unavailable",
                subtitle: "runtime not installed — these cannot boot",
                size: unavailable.reduce(Int64(0)) { $0 + $1.byteCount },
                risk: .safe,
                // One command clears the lot, which is both faster and what the tool documents.
                action: .command(
                    executable: "/usr/bin/xcrun",
                    args: ["simctl", "delete", "unavailable"],
                    displayName: "Delete all unavailable simulators"
                ),
                children: unavailable
            ))
        }

        guard !runtimeNodes.isEmpty else { return nil }
        return ScanNode(
            id: nodeID("devices"),
            title: "Devices",
            subtitle: "app data, databases and sessions per simulator",
            url: URL(fileURLWithPath: NSHomeDirectory())
                .appending(path: "Library/Developer/CoreSimulator/Devices"),
            size: runtimeNodes.reduce(Int64(0)) { $0 + $1.byteCount },
            risk: .careful,
            children: runtimeNodes
        )
    }

    // MARK: - User-level caches

    private func cachesGroup(_ ctx: ScanContext) async throws -> ScanNode? {
        var children: [ScanNode] = []
        let candidates: [(String, String)] = [
            ("Simulator caches", "Library/Developer/CoreSimulator/Caches"),
            ("Simulator logs", "Library/Logs/CoreSimulator")
        ]
        for (title, relative) in candidates {
            let url = ctx.path(relative)
            guard ctx.exists(url) else { continue }
            let size = try await ctx.sizer.size(of: url)
            guard size.bytes > 0 else { continue }
            children.append(ScanNode(
                id: nodeID("cache/\(url.lastPathComponent)"),
                title: title,
                subtitle: "~/\(relative)",
                url: url,
                size: size.bytes,
                risk: .safe,
                action: .removePath(url)
            ))
        }
        guard !children.isEmpty else { return nil }
        return ScanNode(
            id: nodeID("caches"),
            title: "Caches & logs",
            subtitle: "scratch data CoreSimulator rebuilds on demand",
            size: children.reduce(Int64(0)) { $0 + $1.byteCount },
            risk: .safe,
            children: children
        )
    }

    // MARK: - Stored images this app cannot touch

    private static let assetStores = [
        "/System/Library/AssetsV2/com_apple_MobileAsset_iOSSimulatorRuntime",
        "/System/Library/AssetsV2/com_apple_MobileAsset_watchOSSimulatorRuntime",
        "/System/Library/AssetsV2/com_apple_MobileAsset_tvOSSimulatorRuntime",
        "/System/Library/AssetsV2/com_apple_MobileAsset_visionOSSimulatorRuntime"
    ]
    private static let cryptexBundleStore =
        "/Library/Developer/CoreSimulator/Cryptex/Images/bundle"
    private static let sharedCaches = "/Library/Developer/CoreSimulator/Caches"

    /// Runtime images and shared caches that sit outside the user's reach.
    ///
    /// Presented as info rows with copyable commands rather than hidden, because on a machine
    /// with several Xcode upgrades behind it this is frequently the largest reclaimable figure on
    /// the disk — and the user has no way to discover it otherwise.
    private func unreachableGroup(
        _ ctx: ScanContext,
        runtimes: [SimRuntime]
    ) async throws -> ScanNode? {
        ctx.progress("Checking stored runtime images")
        var children: [ScanNode] = []

        // --- SIP-protected asset store
        let referencedAssets = Set(runtimes.compactMap(SimulatorParsing.assetDirectory))
        var orphanAssets: [(URL, Int64)] = []
        for store in Self.assetStores {
            let storeURL = URL(fileURLWithPath: store)
            guard ctx.exists(storeURL) else { continue }
            for asset in try ctx.sizer.directChildren(of: storeURL)
            where asset.pathExtension == "asset" {
                guard !referencedAssets.contains(asset.path) else { continue }
                let size = try await ctx.sizer.size(of: asset)
                orphanAssets.append((asset, size.bytes))
            }
        }
        if !orphanAssets.isEmpty {
            let total = orphanAssets.reduce(Int64(0)) { $0 + $1.1 }
            children.append(ScanNode(
                id: nodeID("orphans/assets"),
                title: "Leftover runtime downloads (SIP-protected)",
                subtitle: "\(orphanAssets.count) simulator image\(orphanAssets.count == 1 ? "" : "s") "
                    + "left behind after the runtime was removed · flagged NeverCollected, so "
                    + "macOS will not reclaim them · only Recovery mode can delete them",
                url: URL(fileURLWithPath: Self.assetStores[0]),
                size: total,
                risk: .info,
                action: .none,
                children: orphanAssets.map { asset, bytes in
                    ScanNode(
                        id: nodeID("orphans/assets/\(asset.lastPathComponent)"),
                        title: Self.assetDescription(asset)
                            ?? (String(asset.lastPathComponent.prefix(12)) + "….asset"),
                        subtitle: "sudo rm -rf \(asset.path)",
                        url: asset,
                        size: bytes,
                        risk: .info,
                        action: .none,
                        isAdvisory: true
                    )
                },
                isAdvisory: true
            ))
        }

        // --- Root-owned Cryptex bundle store: sudo is enough here, no Recovery mode needed
        let cryptexURL = URL(fileURLWithPath: Self.cryptexBundleStore)
        if ctx.exists(cryptexURL) {
            let referencedBundles = Set(runtimes.compactMap(SimulatorParsing.cryptexBundleName))
            var orphanBundles: [(URL, Int64)] = []
            for bundle in try ctx.sizer.directChildren(of: cryptexURL)
            where bundle.lastPathComponent.hasPrefix("SimRuntimeBundle-") {
                guard !referencedBundles.contains(bundle.lastPathComponent) else { continue }
                let size = try await ctx.sizer.size(of: bundle)
                orphanBundles.append((bundle, size.bytes))
            }
            // Only worth a row if it actually holds something. On the development machine all
            // 18 unreferenced bundles turned out to be empty stubs left behind by Xcode
            // upgrades — real leftovers, but 0 B, and a row promising reclaimable space that
            // reclaims nothing is worse than no row.
            if orphanBundles.contains(where: { $0.1 > 0 }) {
                children.append(ScanNode(
                    id: nodeID("orphans/cryptex"),
                    title: "Orphaned runtime bundles",
                    subtitle: "\(orphanBundles.count) bundle\(orphanBundles.count == 1 ? "" : "s")"
                        + " no installed runtime refers to · needs admin rights",
                    url: cryptexURL,
                    size: orphanBundles.reduce(Int64(0)) { $0 + $1.1 },
                    risk: .info,
                    action: .none,
                    children: orphanBundles.map { bundle, bytes in
                        ScanNode(
                            id: nodeID("orphans/cryptex/\(bundle.lastPathComponent)"),
                            title: bundle.lastPathComponent
                                .replacingOccurrences(of: "SimRuntimeBundle-", with: ""),
                            url: bundle,
                            size: bytes,
                            risk: .info,
                            action: .none,
                            isAdvisory: true
                        )
                    },
                    isAdvisory: true
                ))
            }
        }

        // --- Shared caches, root-owned
        let sharedURL = URL(fileURLWithPath: Self.sharedCaches)
        if ctx.exists(sharedURL) {
            let size = try await ctx.sizer.size(of: sharedURL)
            if size.bytes > 0 {
                children.append(ScanNode(
                    id: nodeID("orphans/sharedCaches"),
                    title: "Shared simulator caches",
                    subtitle: "\(Self.sharedCaches) · needs admin rights",
                    url: sharedURL,
                    size: size.bytes,
                    risk: .info,
                    action: .none,
                    isAdvisory: true
                ))
            }
        }

        guard !children.isEmpty else { return nil }
        return ScanNode(
            id: nodeID("orphans"),
            title: "Reclaimable only with admin rights",
            subtitle: "DevCleanerPro never uses sudo — right-click for the exact commands",
            size: children.reduce(Int64(0)) { $0 + $1.byteCount },
            risk: .info,
            action: .none,
            children: children,
            isAdvisory: true
        )
    }

    /// "iOS 18.2 (22C150)" read from the asset's own `Info.plist`, so the row names a version
    /// the user recognises instead of a hash.
    static func assetDescription(_ asset: URL) -> String? {
        let plist = asset.appending(path: "Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let parsed = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil
              ) as? [String: Any],
              let props = parsed["MobileAssetProperties"] as? [String: Any]
        else { return nil }

        let platform = asset.deletingLastPathComponent().lastPathComponent
            .replacingOccurrences(of: "com_apple_MobileAsset_", with: "")
            .replacingOccurrences(of: "SimulatorRuntime", with: "")
        let version = props["SimulatorVersion"] as? String ?? "?"
        let build = props["Build"] as? String ?? "?"
        return "\(platform) \(version) (\(build))"
    }

    /// Actions that let `simctl` do the tidying itself, which is always preferable to a path
    /// deletion because it keeps CoreSimulator's own bookkeeping consistent.
    private func maintenanceGroup(_ ctx: ScanContext) -> ScanNode {
        ScanNode(
            id: nodeID("maintenance"),
            title: "Maintenance",
            subtitle: "let simctl do the work",
            size: 0,
            risk: .safe,
            children: [
                ScanNode(
                    id: nodeID("maintenance/scanAndMount"),
                    title: "Re-scan and mount stored runtimes",
                    subtitle: "re-registers images CoreSimulator has lost track of · note that "
                        + "it stages a second copy rather than adopting the original, so it does "
                        + "not reclaim leftover downloads · runs in the background, so rescan "
                        + "a minute later",
                    size: 0,
                    risk: .safe,
                    action: .command(
                        executable: "/usr/bin/xcrun",
                        args: ["simctl", "runtime", "scan-and-mount"],
                        displayName: "simctl runtime scan-and-mount"
                    )
                ),
                ScanNode(
                    id: nodeID("maintenance/deleteUnused"),
                    title: "Delete runtimes unused for 90 days",
                    subtitle: "simctl decides which; run Rescan afterwards to see the effect",
                    size: 0,
                    risk: .moderate,
                    action: .command(
                        executable: "/usr/bin/xcrun",
                        args: ["simctl", "runtime", "delete", "--notUsedSinceDays", "90"],
                        displayName: "Delete runtimes unused for 90 days"
                    )
                )
            ]
        )
    }

    // MARK: - Pre-delete

    /// Re-asked immediately before deletion, because a simulator can be booted while the
    /// confirmation sheet is open.
    public func preDeleteCheck(_ node: ScanNode, _ ctx: ScanContext) async -> String? {
        guard node.id.hasPrefix(nodeID("device/"))
                || node.id.hasPrefix(nodeID("runtime/"))
                || node.id == nodeID("devices/unavailable")
        else { return nil }

        guard let result = try? await ctx.shell.run(
            tool: "xcrun", ["simctl", "list", "devices", "-j"], timeout: .seconds(30)
        ), result.succeeded,
              let byRuntime = try? SimulatorParsing.devices(
                  fromDeviceListJSON: Data(result.stdout.utf8)
              )
        else { return nil }

        let booted = byRuntime.values.flatMap { $0 }.filter(\.isBooted)
        guard !booted.isEmpty else { return nil }

        if node.id.hasPrefix(nodeID("device/")) {
            let udid = String(node.id.dropFirst(nodeID("device/").count))
            guard booted.contains(where: { $0.udid == udid }) else { return nil }
            return "Simulator is booted — shut it down to delete"
        }
        // A runtime cannot go while anything on it is running.
        if node.id.hasPrefix(nodeID("runtime/")) {
            return "\(booted[0].name) is still booted — shut it down first"
        }
        return nil
    }
}
