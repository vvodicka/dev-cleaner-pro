import Foundation

/// M4 — Android SDK, virtual devices and Gradle caches.
///
/// The SDK is versioned everywhere, so almost every group uses the same rule: the highest
/// version in each family is `careful` because it is what the current project builds against,
/// and the ones below it are a re-download the user has simply not tidied up.
public struct AndroidModule: ScanModule {
    public init() {}

    public var descriptor: ModuleDescriptor {
        ModuleDescriptor(id: "android", title: "Android", systemImage: "smartphone")
    }

    public var roots: [AllowedRoot] {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        return [
            AllowedRoot(home.appending(path: "Library/Android/sdk")),
            AllowedRoot(home.appending(path: ".android/avd")),
            AllowedRoot(home.appending(path: ".android/cache"), deletableItself: true),
            AllowedRoot(home.appending(path: ".gradle")),
            AllowedRoot(home.appending(path: "Library/Caches/Google"))
        ]
    }

    public func isAvailable(_ ctx: ScanContext) async -> Bool {
        ctx.anyExists([
            ctx.path("Library/Android/sdk"),
            ctx.path(".android"),
            ctx.path(".gradle")
        ])
    }

    public func scan(_ ctx: ScanContext) async throws -> ScanNode {
        var groups: [ScanNode] = []

        if let node = try await sdkGroup(ctx) { groups.append(node) }
        if let node = try await avdGroup(ctx) { groups.append(node) }
        if let node = try await gradleGroup(ctx) { groups.append(node) }
        if let node = try await studioCachesGroup(ctx) { groups.append(node) }

        return ScanNode(
            id: descriptor.id,
            title: descriptor.title,
            subtitle: "~/Library/Android · ~/.android · ~/.gradle",
            url: ctx.path("Library/Android/sdk"),
            size: groups.reduce(Int64(0)) { $0 + $1.byteCount },
            risk: .moderate,
            children: groups
        )
    }

    // MARK: - SDK

    /// SDK families that are a plain version-per-folder layout, in the order doc 03 lists them.
    private static let versionedFamilies: [(folder: String, title: String, note: String?)] = [
        ("ndk", "NDK", "native toolchains"),
        ("build-tools", "Build tools", nil),
        ("platforms", "Platforms", "android-XX SDK jars"),
        ("cmake", "CMake", nil),
        ("sources", "Sources", "source jars for reading framework code")
    ]

    private func sdkGroup(_ ctx: ScanContext) async throws -> ScanNode? {
        let sdk = ctx.path("Library/Android/sdk")
        guard ctx.exists(sdk) else { return nil }
        ctx.progress("Measuring Android SDK")

        var children: [ScanNode] = []

        for family in Self.versionedFamilies {
            let root = sdk.appending(path: family.folder)
            guard ctx.exists(root) else { continue }
            let measured = try await ctx.sizer.sizedChildren(of: root)
            guard !measured.isEmpty else { continue }

            let newest = VersionCompare.highest(measured.map { $0.url.lastPathComponent })
            let items = measured.map { url, size in
                let isNewest = url.lastPathComponent == newest
                return ScanNode(
                    id: nodeID("sdk/\(family.folder)/\(url.lastPathComponent)"),
                    title: url.lastPathComponent,
                    subtitle: isNewest
                        ? "newest — likely what your projects build with"
                        : "older \(family.title.lowercased()) · re-installable from the SDK manager",
                    url: url,
                    size: size.bytes,
                    risk: isNewest ? .careful : .moderate,
                    action: .removePath(url)
                )
            }
            children.append(ScanNode(
                id: nodeID("sdk/\(family.folder)"),
                title: family.title,
                subtitle: [family.note, "\(items.count) version\(items.count == 1 ? "" : "s")"]
                    .compactMap { $0 }.joined(separator: " · "),
                url: root,
                size: measured.reduce(Int64(0)) { $0 + $1.size.bytes },
                risk: .moderate,
                children: items
            ))
        }

        if let images = try await systemImages(ctx, sdk: sdk) { children.append(images) }

        // The emulator binary itself: careful, because removing it breaks every AVD until the
        // SDK manager reinstalls it.
        for (folder, title, risk, note) in [
            ("emulator", "Emulator", Risk.careful, "AVDs cannot run without this"),
            ("platform-tools", "Platform tools", Risk.moderate,
             "adb and fastboot · re-installable from the SDK manager"),
            ("tools", "Legacy tools", Risk.moderate,
             "superseded SDK tools kept for old projects")
        ] {
            let url = sdk.appending(path: folder)
            guard ctx.exists(url) else { continue }
            let size = try await ctx.sizer.size(of: url)
            guard size.bytes > 0 else { continue }
            children.append(ScanNode(
                id: nodeID("sdk/\(folder)"),
                title: title,
                subtitle: note,
                url: url,
                size: size.bytes,
                risk: risk,
                action: .removePath(url)
            ))
        }

        guard !children.isEmpty else { return nil }
        return ScanNode(
            id: nodeID("sdk"),
            title: "SDK",
            subtitle: "~/Library/Android/sdk",
            url: sdk,
            size: children.reduce(Int64(0)) { $0 + $1.byteCount },
            risk: .moderate,
            children: children
        )
    }

    /// `system-images/android-XX/<variant>/<abi>` — three levels, so the API level groups the
    /// variants rather than presenting a flat list of indistinguishable ABI folders.
    private func systemImages(_ ctx: ScanContext, sdk: URL) async throws -> ScanNode? {
        let root = sdk.appending(path: "system-images")
        guard ctx.exists(root) else { return nil }

        let apiLevels = try ctx.sizer.directChildren(of: root)
        guard !apiLevels.isEmpty else { return nil }

        let newestAPI = VersionCompare.highest(apiLevels.map { $0.lastPathComponent })
        var levelNodes: [ScanNode] = []

        for api in apiLevels {
            let variants = try await ctx.sizer.sizedChildren(of: api)
            guard !variants.isEmpty else { continue }
            let isNewest = api.lastPathComponent == newestAPI

            let variantNodes = variants.map { url, size in
                ScanNode(
                    id: nodeID("sdk/system-images/\(api.lastPathComponent)/\(url.lastPathComponent)"),
                    title: url.lastPathComponent,
                    subtitle: "emulator OS image for \(api.lastPathComponent)"
                        + " · re-downloaded by the SDK manager",
                    url: url,
                    size: size.bytes,
                    risk: isNewest ? .careful : .moderate,
                    action: .removePath(url)
                )
            }
            levelNodes.append(ScanNode(
                id: nodeID("sdk/system-images/\(api.lastPathComponent)"),
                title: api.lastPathComponent,
                subtitle: isNewest ? "newest API level" : nil,
                url: api,
                size: variants.reduce(Int64(0)) { $0 + $1.size.bytes },
                risk: isNewest ? .careful : .moderate,
                children: variantNodes
            ))
        }
        guard !levelNodes.isEmpty else { return nil }

        return ScanNode(
            id: nodeID("sdk/system-images"),
            title: "System images",
            subtitle: "emulator OS images · \(levelNodes.count) API level"
                + (levelNodes.count == 1 ? "" : "s"),
            url: root,
            size: levelNodes.reduce(Int64(0)) { $0 + $1.byteCount },
            risk: .moderate,
            children: levelNodes
        )
    }

    // MARK: - AVDs

    /// An AVD is a folder plus a sibling `.ini` that points at it. Deleting one without the other
    /// leaves Android Studio showing a device that cannot start, so they go together as one item.
    private func avdGroup(_ ctx: ScanContext) async throws -> ScanNode? {
        let root = ctx.path(".android/avd")
        guard ctx.exists(root) else { return nil }
        ctx.progress("Measuring virtual devices")

        let entries = try ctx.sizer.directChildren(of: root)
        let avdFolders = entries.filter { $0.pathExtension == "avd" }
        guard !avdFolders.isEmpty else { return nil }

        var children: [ScanNode] = []
        for folder in avdFolders {
            let size = try await ctx.sizer.size(of: folder)
            let stem = folder.deletingPathExtension().lastPathComponent
            let ini = root.appending(path: "\(stem).ini")
            let hasIni = ctx.exists(ini)

            let display = readDisplayName(from: folder) ?? stem
            var parts: [String] = []
            if let target = readTarget(from: folder) { parts.append(target) }
            if let modified = (try? folder.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate {
                parts.append("last used \(XcodeModule.dateText(modified))")
            }

            children.append(ScanNode(
                id: nodeID("avd/\(stem)"),
                title: display,
                subtitle: parts.isEmpty ? nil : parts.joined(separator: " · "),
                url: folder,
                size: size.bytes,
                // Careful: an AVD holds installed apps, accounts and app data, and recreating it
                // is not the same as getting it back.
                risk: .careful,
                action: hasIni ? .removePaths([folder, ini]) : .removePath(folder)
            ))
        }

        return ScanNode(
            id: nodeID("avd"),
            title: "Virtual devices",
            subtitle: "~/.android/avd · installed apps and app data live here",
            url: root,
            size: children.reduce(Int64(0)) { $0 + $1.byteCount },
            risk: .careful,
            children: children
        )
    }

    /// `avd.ini.displayname` from the AVD's own `config.ini`, which is what Android Studio shows.
    private func readDisplayName(from folder: URL) -> String? {
        iniValue(in: folder.appending(path: "config.ini"), key: "avd.ini.displayname")
    }

    private func readTarget(from folder: URL) -> String? {
        let config = folder.appending(path: "config.ini")
        if let api = iniValue(in: config, key: "image.sysdir.1") {
            // "system-images/android-36/google_apis_playstore/arm64-v8a/" → "android-36"
            let parts = api.split(separator: "/")
            if let level = parts.first(where: { $0.hasPrefix("android-") }) {
                return String(level)
            }
        }
        return iniValue(in: config, key: "target")
    }

    private func iniValue(in file: URL, key: String) -> String? {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespaces) == key
            else { continue }
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        return nil
    }

    // MARK: - Gradle

    private func gradleGroup(_ ctx: ScanContext) async throws -> ScanNode? {
        let root = ctx.path(".gradle")
        guard ctx.exists(root) else { return nil }
        ctx.progress("Measuring Gradle caches")

        var children: [ScanNode] = []

        // `caches` holds one folder per Gradle version plus the shared `modules-2` dependency
        // cache. Splitting them matters: the version folders are pure build output, while
        // modules-2 is a download cache worth several minutes of network time.
        let caches = root.appending(path: "caches")
        if ctx.exists(caches) {
            let measured = try await ctx.sizer.sizedChildren(of: caches)
            let items = measured.map { url, size -> ScanNode in
                let name = url.lastPathComponent
                let isDependencyCache = name == "modules-2"
                return ScanNode(
                    id: nodeID("gradle/caches/\(name)"),
                    title: name,
                    subtitle: isDependencyCache
                        ? "downloaded dependencies — re-fetched from the network"
                        : "build output for Gradle \(name) · regenerated on next build",
                    url: url,
                    size: size.bytes,
                    risk: isDependencyCache ? .moderate : .safe,
                    action: .removePath(url)
                )
            }
            if !items.isEmpty {
                children.append(ScanNode(
                    id: nodeID("gradle/caches"),
                    title: "Build caches",
                    subtitle: "~/.gradle/caches",
                    url: caches,
                    size: measured.reduce(Int64(0)) { $0 + $1.size.bytes },
                    risk: .safe,
                    children: items
                ))
            }
        }

        // Wrapper distributions: one Gradle install per project version. The newest is the one a
        // current build will use, so removing it costs a re-download at the worst moment.
        let dists = root.appending(path: "wrapper/dists")
        if ctx.exists(dists) {
            let measured = try await ctx.sizer.sizedChildren(of: dists)
            let newest = VersionCompare.highest(measured.map { $0.url.lastPathComponent })
            let items = measured.map { url, size in
                ScanNode(
                    id: nodeID("gradle/dists/\(url.lastPathComponent)"),
                    title: url.lastPathComponent,
                    subtitle: "a full Gradle install · re-downloaded by the wrapper",
                    url: url,
                    size: size.bytes,
                    risk: url.lastPathComponent == newest ? .careful : .moderate,
                    action: .removePath(url)
                )
            }
            if !items.isEmpty {
                children.append(ScanNode(
                    id: nodeID("gradle/dists"),
                    title: "Wrapper distributions",
                    subtitle: "Gradle itself, one copy per version",
                    url: dists,
                    size: measured.reduce(Int64(0)) { $0 + $1.size.bytes },
                    risk: .moderate,
                    children: items
                ))
            }
        }

        for (folder, title) in [("daemon", "Daemon logs"), ("native", "Native libraries")] {
            let url = root.appending(path: folder)
            guard ctx.exists(url) else { continue }
            let size = try await ctx.sizer.size(of: url)
            guard size.bytes > 0 else { continue }
            children.append(ScanNode(
                id: nodeID("gradle/\(folder)"),
                title: title,
                url: url,
                size: size.bytes,
                risk: .safe,
                action: .removePath(url)
            ))
        }

        guard !children.isEmpty else { return nil }
        return ScanNode(
            id: nodeID("gradle"),
            title: "Gradle",
            subtitle: "~/.gradle",
            url: root,
            size: children.reduce(Int64(0)) { $0 + $1.byteCount },
            risk: .safe,
            children: children
        )
    }

    private func studioCachesGroup(_ ctx: ScanContext) async throws -> ScanNode? {
        let google = ctx.path("Library/Caches/Google")
        guard ctx.exists(google) else { return nil }

        let measured = try await ctx.sizer.sizedChildren(of: google)
        let studio = measured.filter { $0.url.lastPathComponent.hasPrefix("AndroidStudio") }
        guard !studio.isEmpty else { return nil }

        let newest = VersionCompare.highest(studio.map { $0.url.lastPathComponent })
        let children = studio.map { url, size in
            ScanNode(
                id: nodeID("studio/\(url.lastPathComponent)"),
                title: url.lastPathComponent,
                subtitle: url.lastPathComponent == newest ? "current version" : "old version",
                url: url,
                size: size.bytes,
                risk: .safe,
                action: .removePath(url)
            )
        }

        return ScanNode(
            id: nodeID("studio"),
            title: "Android Studio caches",
            subtitle: "~/Library/Caches/Google",
            url: google,
            size: studio.reduce(Int64(0)) { $0 + $1.size.bytes },
            risk: .safe,
            children: children
        )
    }

    // MARK: - Pre-delete

    /// A running emulator has its AVD's disk images open; removing them under it corrupts the
    /// device rather than simply stopping it.
    public func preDeleteCheck(_ node: ScanNode, _ ctx: ScanContext) async -> String? {
        let guardedPrefixes = [nodeID("avd"), nodeID("sdk/emulator"), nodeID("sdk/system-images")]
        guard guardedPrefixes.contains(where: { node.id.hasPrefix($0) }) else { return nil }

        let processes = ProcessCheck(shell: ctx.shell)
        guard await processes.isRunning(pattern: "qemu-system|Android Emulator|emulator/emulator")
        else { return nil }
        return "An Android emulator is running — quit it first"
    }
}
