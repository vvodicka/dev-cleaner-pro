import Foundation

/// M9 — user logs and diagnostic reports.
///
/// Overlaps with other modules by construction: `~/Library/Logs/JetBrains` is 2.1 GB on this
/// machine and already appears under JetBrains, `Logs/CoreSimulator` under Simulators. Those are
/// skipped here rather than listed greyed, so every row in this module is one you can act on.
public struct LogsModule: ScanModule {
    public init() {}

    public var descriptor: ModuleDescriptor {
        ModuleDescriptor(id: "logs", title: "Logs", systemImage: "doc.text.magnifyingglass")
    }

    public var roots: [AllowedRoot] {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        return [AllowedRoot(home.appending(path: "Library/Logs"))]
    }

    /// Log folders another module already accounts for.
    private static let ownedElsewhere: [String: String] = [
        "JetBrains": "JetBrains",
        "CoreSimulator": "Simulators",
        "Google": "Android",
        "Claude": "AI tools",
        "Antigravity": "AI tools",
        "Cursor": "AI tools"
    ]

    public func isAvailable(_ ctx: ScanContext) async -> Bool {
        ctx.exists(ctx.path("Library/Logs"))
    }

    public func scan(_ ctx: ScanContext) async throws -> ScanNode {
        let root = ctx.path("Library/Logs")
        ctx.progress("Measuring ~/Library/Logs")

        let measured = try await ctx.sizer.sizedChildren(of: root)
        var children: [ScanNode] = []
        var referredCount = 0

        for (url, size) in measured where size.bytes > 0 {
            let name = url.lastPathComponent

            // Owned by another module: it is listed there, where it can be deleted.
            if Self.ownedElsewhere[name] != nil {
                referredCount += 1
                continue
            }

            children.append(ScanNode(
                id: nodeID(name),
                title: name,
                subtitle: name == "DiagnosticReports"
                    ? "crash reports — kept only for diagnostics"
                    : "diagnostic logs written by \(name)",
                url: url,
                size: size.bytes,
                risk: .safe,
                action: .removePath(url)
            ))
        }
        guard !children.isEmpty else {
            throw ScanFailure.empty("No logs found")
        }

        return ScanNode(
            id: descriptor.id,
            title: descriptor.title,
            subtitle: "~/Library/Logs"
                + (referredCount > 0
                   ? " · \(referredCount) shown under their own module instead"
                   : ""),
            url: root,
            size: children.reduce(Int64(0)) { $0 + $1.byteCount },
            risk: .safe,
            children: children
        )
    }
}
