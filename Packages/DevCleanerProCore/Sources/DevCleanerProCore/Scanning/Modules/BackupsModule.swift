import Foundation

/// M10 — iOS device backups and Time Machine local snapshots.
///
/// Both are `careful` for the same reason: they are the only copy of something. An iOS backup is
/// a phone's entire contents, and a local snapshot is what a Time Machine restore falls back on
/// when the external disk is not attached.
///
/// This is also the one module that genuinely needs Full Disk Access — `MobileSync/Backup` is
/// TCC-protected, and without the grant it cannot even be listed.
public struct BackupsModule: ScanModule {
    public init() {}

    public var descriptor: ModuleDescriptor {
        ModuleDescriptor(
            id: "backups",
            title: "Backups & snapshots",
            systemImage: "clock.arrow.circlepath"
        )
    }

    public var roots: [AllowedRoot] {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        return [AllowedRoot(home.appending(path: "Library/Application Support/MobileSync/Backup"))]
    }

    public func isAvailable(_ ctx: ScanContext) async -> Bool {
        if ctx.exists(ctx.path("Library/Application Support/MobileSync/Backup")) { return true }
        return await ctx.shell.has("tmutil")
    }

    public func scan(_ ctx: ScanContext) async throws -> ScanNode {
        var children: [ScanNode] = []
        if let node = try await deviceBackups(ctx) { children.append(node) }
        if let node = await localSnapshots(ctx) { children.append(node) }

        guard !children.isEmpty else {
            throw ScanFailure.empty("No iOS backups or Time Machine snapshots on this Mac")
        }

        return ScanNode(
            id: descriptor.id,
            title: descriptor.title,
            subtitle: "the only copy of something — check twice before removing anything here",
            size: children.reduce(Int64(0)) { $0 + $1.byteCount },
            risk: .careful,
            children: children
        )
    }

    // MARK: - iOS backups

    private func deviceBackups(_ ctx: ScanContext) async throws -> ScanNode? {
        let root = ctx.path("Library/Application Support/MobileSync/Backup")
        guard ctx.exists(root) else { return nil }
        ctx.progress("Reading iOS backups")

        let entries = try ctx.sizer.directChildren(of: root)
        guard !entries.isEmpty else {
            // Present but unlistable means the TCC grant is missing, which is worth saying
            // plainly rather than reporting an empty folder.
            let readable = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) != nil
            guard !readable else { return nil }
            return ScanNode(
                id: nodeID("devices"),
                title: "iOS device backups",
                subtitle: "cannot be read without Full Disk Access — grant it and rescan",
                url: root,
                size: nil,
                risk: .info,
                action: .none,
                isAdvisory: true
            )
        }

        var children: [ScanNode] = []
        for backup in entries {
            let size = try await ctx.sizer.size(of: backup)
            let info = readInfoPlist(at: backup)
            var parts: [String] = []
            if let version = info.productVersion { parts.append("iOS \(version)") }
            if let date = info.lastBackupDate {
                parts.append("last backup \(XcodeModule.dateText(date))")
            }
            parts.append(backup.lastPathComponent.prefix(8) + "…")

            children.append(ScanNode(
                id: nodeID("device/\(backup.lastPathComponent)"),
                title: info.deviceName ?? backup.lastPathComponent,
                subtitle: parts.joined(separator: " · "),
                url: backup,
                size: size.bytes,
                risk: .careful,
                action: .removePath(backup)
            ))
        }
        guard !children.isEmpty else { return nil }

        return ScanNode(
            id: nodeID("devices"),
            title: "iOS device backups",
            subtitle: "the entire contents of a phone — check it is backed up elsewhere first",
            url: root,
            size: children.reduce(Int64(0)) { $0 + $1.byteCount },
            risk: .careful,
            children: children
        )
    }

    private struct BackupInfo {
        var deviceName: String?
        var productVersion: String?
        var lastBackupDate: Date?
    }

    /// `Info.plist` inside a backup carries the readable device name and dates. Read with
    /// `PropertyListSerialization` because these are binary plists.
    private func readInfoPlist(at backup: URL) -> BackupInfo {
        var info = BackupInfo()
        let plist = backup.appending(path: "Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let parsed = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil
              ) as? [String: Any]
        else { return info }

        info.deviceName = parsed["Device Name"] as? String ?? parsed["Display Name"] as? String
        info.productVersion = parsed["Product Version"] as? String
        info.lastBackupDate = parsed["Last Backup Date"] as? Date
        return info
    }

    // MARK: - Time Machine local snapshots

    /// Snapshot sizes are not knowable without `tmutil` doing a full calculation, so the rows say
    /// "size n/a" rather than inventing a figure. `thinlocalsnapshots` is what actually reclaims
    /// space, and macOS runs it on its own under disk pressure — which is why these are
    /// `moderate` rather than something to hurry into.
    private func localSnapshots(_ ctx: ScanContext) async -> ScanNode? {
        guard let tmutil = await ctx.shell.path(of: "tmutil") else { return nil }
        ctx.progress("Listing Time Machine snapshots")

        guard let result = try? await ctx.shell.run(
            executable: tmutil, ["listlocalsnapshots", "/"], timeout: .seconds(60)
        ), result.succeeded else { return nil }

        let names = result.stdout
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("com.apple.TimeMachine.") }
        guard !names.isEmpty else { return nil }

        let children = names.map { name -> ScanNode in
            // "com.apple.TimeMachine.2026-09-10-120400.local" → "2026-09-10 12:04"
            let stamp = name
                .replacingOccurrences(of: "com.apple.TimeMachine.", with: "")
                .replacingOccurrences(of: ".local", with: "")
            return ScanNode(
                id: nodeID("snapshot/\(name)"),
                title: readableStamp(stamp) ?? stamp,
                subtitle: "size n/a — macOS thins these automatically under disk pressure",
                size: nil,
                risk: .moderate,
                action: .command(
                    executable: tmutil,
                    args: ["deletelocalsnapshots", stamp],
                    displayName: "Delete local snapshot \(stamp)"
                )
            )
        }

        return ScanNode(
            id: nodeID("snapshots"),
            title: "Time Machine local snapshots",
            subtitle: "\(children.count) snapshot\(children.count == 1 ? "" : "s") · what a "
                + "restore falls back on when the backup disk is not attached",
            size: nil,
            risk: .moderate,
            children: children
        )
    }

    /// "2026-09-10-120400" → "2026-09-10 12:04"
    private func readableStamp(_ stamp: String) -> String? {
        let parts = stamp.split(separator: "-")
        guard parts.count == 4, parts[3].count >= 4 else { return nil }
        let time = parts[3]
        let hh = time.prefix(2)
        let mm = time.dropFirst(2).prefix(2)
        return "\(parts[0])-\(parts[1])-\(parts[2]) \(hh):\(mm)"
    }
}
