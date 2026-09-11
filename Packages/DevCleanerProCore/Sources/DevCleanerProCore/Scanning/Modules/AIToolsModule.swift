import Foundation

/// M8 — caches and local state of AI development tools.
///
/// These apps are mostly Electron, so each one has the same handful of Chromium cache folders
/// plus a few directories that are emphatically not caches — conversation transcripts, pulled
/// models, agent session state. The distinction is the whole value of this module: a blanket
/// "delete the app's Application Support folder" would take a developer's entire chat history
/// with it.
public struct AIToolsModule: ScanModule {
    public init() {}

    public var descriptor: ModuleDescriptor {
        ModuleDescriptor(id: "ai", title: "AI tools", systemImage: "sparkles")
    }

    /// Chromium's cache directories, identical across every Electron app.
    private static let electronCaches = [
        "Cache", "Code Cache", "GPUCache", "CachedData", "CachedExtensionVSIXs",
        "CachedProfilesData", "CachedConfigurations", "DawnCache", "DawnWebGPUCache",
        "ShaderCache", "blob_storage", "Crashpad", "logs"
    ]

    /// A tool, and how to classify what is inside it.
    struct Tool {
        let id: String
        let title: String
        /// Home-relative root.
        let path: String
        /// Subfolders that hold real user data, with the reason shown on the row.
        var precious: [String: String] = [:]
        /// Subfolders that are caches beyond the standard Electron set.
        var extraCaches: [String] = []
        /// When true, anything unrecognised is info-only rather than deletable — the safe
        /// default for a folder that mixes state and cache.
        var unknownIsInfo = true
    }

    static let tools: [Tool] = [
        Tool(
            id: "claude-desktop",
            title: "Claude Desktop",
            path: "Library/Application Support/Claude",
            precious: [
                "local-agent-mode-sessions": "agent session state",
                "IndexedDB": "app data",
                "Local Storage": "app data",
                "WebStorage": "app data",
                "Session Storage": "app data"
            ],
            extraCaches: ["vm_bundles", "claude-code-vm", "dxt-staging", "Partitions"]
        ),
        Tool(
            id: "claude-desktop-cache",
            title: "Claude Desktop caches",
            path: "Library/Caches/com.anthropic.claudefordesktop",
            unknownIsInfo: false
        ),
        Tool(
            id: "claude-code",
            title: "Claude Code",
            path: ".claude",
            precious: [
                "projects": "conversation transcripts",
                "history.jsonl": "command history",
                "file-history": "edit history",
                "backups": "backups of files it changed",
                "todos": "saved task lists",
                "plugins": "installed plugins",
                "settings.json": "your settings",
                "agents": "your custom agents",
                "commands": "your custom commands",
                "skills": "your skills"
            ],
            extraCaches: ["downloads", "cache", "statsig", "shell-snapshots", "debug"]
        ),
        Tool(
            id: "gemini",
            title: "Gemini CLI",
            path: ".gemini",
            precious: ["config": "your settings"],
            extraCaches: ["antigravity", "antigravity-cli", "tmp"]
        ),
        Tool(
            id: "antigravity-home",
            title: "Antigravity",
            path: ".antigravity",
            extraCaches: ["cache"]
        ),
        Tool(
            id: "antigravity-app",
            title: "Antigravity app data",
            path: "Library/Application Support/Antigravity",
            precious: ["User": "your settings, keybindings and extensions"]
        ),
        Tool(
            id: "copilot",
            title: "GitHub Copilot",
            path: ".cache/github-copilot",
            unknownIsInfo: false
        ),
        Tool(
            id: "cursor",
            title: "Cursor",
            path: "Library/Application Support/Cursor",
            precious: ["User": "your settings, keybindings and extensions"]
        ),
        Tool(
            id: "vscode",
            title: "VS Code",
            path: "Library/Application Support/Code",
            precious: ["User": "your settings, keybindings and extensions"]
        ),
        Tool(
            id: "ollama",
            title: "Ollama models",
            path: ".ollama",
            precious: ["models": "pulled models — several GB each to re-download"]
        ),
        Tool(
            id: "lmstudio",
            title: "LM Studio",
            path: ".lmstudio",
            precious: ["models": "downloaded models"]
        )
    ]

    /// What each cache folder is for, so no row is offered without an explanation.
    static func describeCache(_ name: String) -> String {
        switch name {
        case "Cache", "Code Cache": "web content and compiled script cache"
        case "GPUCache", "ShaderCache", "DawnCache", "DawnWebGPUCache": "graphics shader cache"
        case "CachedData", "CachedProfilesData", "CachedConfigurations":
            "compiled editor data — rebuilt on next launch"
        case "CachedExtensionVSIXs": "downloaded extension archives"
        case "blob_storage": "temporary web blobs"
        case "Crashpad": "crash reports"
        case "logs": "diagnostic logs"
        case "vm_bundles": "downloaded VM images for the sandboxed runtime — re-downloaded on demand"
        case "claude-code-vm": "the sandbox VM image — re-downloaded on demand"
        case "dxt-staging": "staging area for extension installs"
        case "Partitions": "per-site web storage partitions"
        case "downloads": "downloaded release archives"
        case "statsig": "feature-flag cache"
        case "shell-snapshots": "captured shell environments"
        case "debug": "debug traces"
        case "antigravity", "antigravity-cli": "downloaded tool binaries"
        case "tmp": "temporary files"
        case "project-context", "project-index": "indexed copy of your code — rebuilt on demand"
        case "Cache.db", "Cache.db-shm", "Cache.db-wal": "HTTP cache database"
        default: "cache — rebuilt when needed"
        }
    }

    public var roots: [AllowedRoot] {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        return Self.tools.map { AllowedRoot(home.appending(path: $0.path)) }
    }

    public func isAvailable(_ ctx: ScanContext) async -> Bool {
        ctx.anyExists(Self.tools.map { ctx.path($0.path) })
    }

    public func scan(_ ctx: ScanContext) async throws -> ScanNode {
        ctx.progress("Measuring AI tool caches")
        var children: [ScanNode] = []

        for tool in Self.tools {
            let root = ctx.path(tool.path)
            guard ctx.exists(root) else { continue }
            guard let node = try await toolNode(ctx, tool: tool, root: root) else { continue }
            children.append(node)
        }

        return ScanNode(
            id: descriptor.id,
            title: descriptor.title,
            subtitle: "model, session and Electron caches",
            size: children.reduce(Int64(0)) { $0 + $1.byteCount },
            risk: .safe,
            children: children
        )
    }

    private func toolNode(
        _ ctx: ScanContext,
        tool: Tool,
        root: URL
    ) async throws -> ScanNode? {
        let measured = try await ctx.sizer.sizedChildren(of: root)

        // A leaf-shaped tool (a plain cache directory) is one row, not a group.
        guard !measured.isEmpty else {
            let size = try await ctx.sizer.size(of: root)
            guard size.bytes > 0 else { return nil }
            return ScanNode(
                id: nodeID(tool.id),
                title: tool.title,
                subtitle: "~/\(tool.path)",
                url: root,
                size: size.bytes,
                risk: .safe,
                action: .removePath(root)
            )
        }

        var items: [ScanNode] = []
        var tail: [(name: String, bytes: Int64)] = []
        for (url, size) in measured {
            guard size.bytes > 0 else { continue }
            let name = url.lastPathComponent

            if let reason = tool.precious[name] {
                items.append(ScanNode(
                    id: nodeID("\(tool.id)/\(name)"),
                    title: name,
                    subtitle: reason,
                    url: url,
                    size: size.bytes,
                    risk: .careful,
                    action: .removePath(url)
                ))
                continue
            }

            let isCache = Self.electronCaches.contains(name) || tool.extraCaches.contains(name)
            if isCache {
                items.append(ScanNode(
                    id: nodeID("\(tool.id)/\(name)"),
                    title: name,
                    subtitle: Self.describeCache(name),
                    url: url,
                    size: size.bytes,
                    risk: .safe,
                    action: .removePath(url)
                ))
                continue
            }

            // Unrecognised: info by default. Guessing that an unknown folder is a cache is how
            // an app like this loses someone's data.
            // Everything unrecognised goes into one row, whatever its size. A row per entry
            // reads "Safe" beside a checkbox that is not there, which is worse than not listing
            // it: it looks like something you can act on and then refuses.
            guard !tool.unknownIsInfo else {
                tail.append((name, size.bytes))
                continue
            }
            items.append(ScanNode(
                id: nodeID("\(tool.id)/\(name)"),
                title: name,
                subtitle: Self.describeCache(name),
                url: url,
                size: size.bytes,
                risk: .safe,
                action: .removePath(url)
            ))
        }

        if !tail.isEmpty {
            let bytes = tail.reduce(Int64(0)) { $0 + $1.bytes }
            let biggest = tail.max { $0.bytes < $1.bytes }
            items.append(ScanNode(
                id: nodeID("\(tool.id)/__other"),
                title: "Other app data",
                subtitle: "\(tail.count) item\(tail.count == 1 ? "" : "s") not recognised as "
                    + "cache — settings, state and databases"
                    + (biggest.map { ", largest is \($0.name)" } ?? "")
                    + " · left alone, but Reveal in Finder if you want a look",
                url: root,
                size: bytes,
                risk: .info,
                action: .none,
                // Worth a row: it is real space, and the user may want to deal with it by hand.
                isAdvisory: true
            ))
        }
        guard !items.isEmpty else { return nil }

        let deletable = items.filter(\.isDeletable).reduce(Int64(0)) { $0 + $1.byteCount }
        return ScanNode(
            id: nodeID(tool.id),
            title: tool.title,
            subtitle: "~/\(tool.path) · \(ByteFormatting.string(deletable)) removable",
            url: root,
            size: items.reduce(Int64(0)) { $0 + $1.byteCount },
            risk: .safe,
            children: items
        )
    }
}
