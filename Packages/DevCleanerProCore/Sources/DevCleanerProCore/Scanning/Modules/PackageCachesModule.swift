import Foundation

/// M6 — package manager download caches.
///
/// Declarative on purpose: every entry here is "one root, one risk, sometimes a tool that can
/// clean itself", so a table beats fifteen near-identical methods and makes adding a manager a
/// one-line change.
///
/// Where a manager offers its own clean command, that is preferred over deleting the directory:
/// `npm` and `pnpm` keep an index alongside the content, and removing the folder underneath them
/// leaves that index describing files that are no longer there.
public struct PackageCachesModule: ScanModule {
    public init() {}

    public var descriptor: ModuleDescriptor {
        ModuleDescriptor(id: "packages", title: "Package caches", systemImage: "archivebox")
    }

    /// One package manager cache.
    struct Entry {
        let id: String
        let title: String
        /// Home-relative paths. All that exist are measured; the first is used for Reveal.
        let paths: [String]
        let risk: Risk
        var note: String?
        /// Tool whose own clean command is preferred, plus its arguments.
        var cleanTool: (tool: String, args: [String])?
    }

    static let entries: [Entry] = [
        Entry(id: "npm", title: "npm", paths: [".npm"], risk: .safe,
              note: "downloaded packages — re-fetched on next install",
              cleanTool: ("npm", ["cache", "clean", "--force"])),
        Entry(id: "yarn", title: "Yarn", paths: ["Library/Caches/Yarn", ".yarn/berry/cache"],
              risk: .safe),
        Entry(id: "pnpm", title: "pnpm", paths: ["Library/Caches/pnpm", "Library/pnpm/store"],
              risk: .safe,
              note: "content-addressed store — pnpm's own prune keeps its index consistent",
              cleanTool: ("pnpm", ["store", "prune"])),
        Entry(id: "pip", title: "pip", paths: ["Library/Caches/pip"], risk: .safe),
        Entry(id: "uv", title: "uv", paths: [".cache/uv"], risk: .safe,
              note: "downloaded Python wheels — re-fetched on next sync",
              cleanTool: ("uv", ["cache", "clean"])),
        Entry(id: "cocoapods-cache", title: "CocoaPods cache",
              paths: ["Library/Caches/CocoaPods"], risk: .safe),
        Entry(id: "cocoapods-repos", title: "CocoaPods specs", paths: [".cocoapods/repos"],
              risk: .moderate,
              note: "the podspec repository — a large clone, re-cloned by `pod setup`"),
        Entry(id: "homebrew", title: "Homebrew downloads", paths: ["Library/Caches/Homebrew"],
              risk: .safe, note: "downloaded bottles — re-downloaded when needed"),
        Entry(id: "node-gyp", title: "node-gyp headers", paths: ["Library/Caches/node-gyp"],
              risk: .safe),
        Entry(id: "cargo", title: "Cargo", paths: [".cargo/registry/cache", ".cargo/git"],
              risk: .moderate, note: "crate sources — re-downloaded on next build"),
        Entry(id: "go-build", title: "Go build cache", paths: [".cache/go-build"], risk: .safe),
        Entry(id: "go-mod", title: "Go module cache", paths: ["go/pkg/mod"], risk: .moderate,
              note: "downloaded modules — re-fetched on next build"),
        Entry(id: "maven", title: "Maven repository", paths: [".m2/repository"], risk: .moderate,
              note: "re-downloaded on next build, which can take a while"),
        Entry(id: "puppeteer", title: "Puppeteer browsers", paths: [".cache/puppeteer"],
              risk: .moderate, note: "full browser downloads"),
        Entry(id: "playwright", title: "Playwright browsers",
              paths: ["Library/Caches/ms-playwright"], risk: .moderate,
              note: "full browser downloads · reinstall with `npx playwright install`"),
        Entry(id: "nuget", title: "NuGet packages", paths: [".nuget/packages"], risk: .moderate),
        Entry(id: "dotnet", title: ".NET SDK data", paths: [".dotnet"], risk: .careful,
              note: "includes installed SDK state, not only cache"),
        Entry(id: "composer", title: "Composer", paths: [".composer/cache"], risk: .safe),
        Entry(id: "bundler", title: "Bundler", paths: [".bundle/cache"], risk: .safe),
        Entry(id: "nvm", title: "nvm downloads", paths: [".nvm/.cache"], risk: .safe),
        Entry(id: "bun", title: "Bun", paths: [".bun/install/cache"], risk: .safe),
        Entry(id: "deno", title: "Deno", paths: [".deno"], risk: .moderate),
        Entry(id: "pyenv", title: "pyenv downloads", paths: [".pyenv/cache"], risk: .safe),
        // Found by surveying the disk rather than from the spec — 506 MB, 125 MB and 423 MB
        // respectively on the development machine.
        Entry(id: "swiftpm", title: "Swift Package Manager",
              paths: ["Library/Caches/org.swift.swiftpm", ".swiftpm"], risk: .moderate,
              note: "cloned package repositories — re-fetched on next resolve"),
        Entry(id: "typescript", title: "TypeScript type definitions",
              paths: ["Library/Caches/typescript"], risk: .safe,
              note: "auto-acquired @types packages"),
        Entry(id: "playwright-go", title: "Playwright (Go) browsers",
              paths: ["Library/Caches/ms-playwright-go"], risk: .moderate,
              note: "full browser downloads"),
        Entry(id: "rbenv", title: "rbenv Ruby builds",
              paths: [".rbenv/versions", ".rbenv/cache"], risk: .careful,
              note: "installed Ruby versions, not only cache — rebuilding one takes minutes"),
        Entry(id: "electron", title: "Electron downloads",
              paths: ["Library/Caches/electron", "Library/Caches/electron-builder"],
              risk: .safe, note: "prebuilt Electron binaries"),
        Entry(id: "cypress", title: "Cypress binaries",
              paths: ["Library/Caches/Cypress"], risk: .moderate,
              note: "one full Cypress app per version"),
        Entry(id: "sonar", title: "SonarLint analyzers",
              paths: [".sonarlint", ".sonar"], risk: .safe),
        Entry(id: "rustup", title: "rustup toolchains",
              paths: [".rustup/toolchains", ".rustup/downloads"], risk: .careful,
              note: "installed Rust toolchains, not only cache"),
        Entry(id: "conda", title: "conda packages",
              paths: [".conda/pkgs", "miniconda3/pkgs", "anaconda3/pkgs"], risk: .moderate),
        Entry(id: "sdkman", title: "SDKMAN candidates",
              paths: [".sdkman/archives", ".sdkman/tmp"], risk: .safe,
              note: "downloaded archives, not the installed SDKs"),
        Entry(id: "gem", title: "RubyGems cache",
              paths: [".gem/cache"], risk: .safe),
        Entry(id: "julia", title: "Julia packages",
              paths: [".julia/packages", ".julia/artifacts"], risk: .moderate)
    ]

    public var roots: [AllowedRoot] {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        return Self.entries.flatMap { entry in
            entry.paths.map { AllowedRoot(home.appending(path: $0), deletableItself: true) }
        }
    }

    public func isAvailable(_ ctx: ScanContext) async -> Bool {
        Self.entries.contains { entry in
            ctx.anyExists(entry.paths.map { ctx.path($0) })
        }
    }

    public func scan(_ ctx: ScanContext) async throws -> ScanNode {
        ctx.progress("Measuring package caches")

        // Measured concurrently, not one after another. Sequentially this module ran past its
        // own 60 s timeout: ~/.npm alone holds tens of thousands of small files, and there are
        // two dozen entries behind it. The walks are I/O bound, so overlapping them costs
        // nothing and turns a minute into seconds.
        let present = Self.entries.compactMap { entry -> (Entry, [URL])? in
            let urls = entry.paths.map { ctx.path($0) }.filter(ctx.exists)
            return urls.isEmpty ? nil : (entry, urls)
        }

        // Each entry also gets its own budget. `~/.cocoapods/repos` holds 1.82 million files and
        // takes ~45 s to measure — `du` itself needs 42 s. The budget is generous enough that it
        // normally succeeds, and exists so that one pathological podspec checkout
        // would take the module past its timeout and lose the other fourteen results.
        let measured = await withTaskGroup(
            of: (index: Int, size: DirectorySize?).self,
            returning: [Int: DirectorySize?].self
        ) { group in
            for (index, item) in present.enumerated() {
                group.addTask {
                    var total = DirectorySize.zero
                    var anyTimedOut = false
                    for url in item.1 {
                        guard let size = await ctx.sizer.size(of: url, budget: .seconds(120))
                        else {
                            anyTimedOut = true
                            continue
                        }
                        total += size
                    }
                    return (index, anyTimedOut && total.bytes == 0 ? nil : total)
                }
            }
            var results: [Int: DirectorySize?] = [:]
            for await result in group {
                results[result.index] = result.size
            }
            return results
        }

        var children: [ScanNode] = []
        var timedOutCount = 0
        for (index, item) in present.enumerated() {
            let entry = item.0
            let urls = item.1

            // Measured but too slow to finish: still offer it, with an honest "unknown" size
            // rather than a zero that reads as "nothing here".
            guard let result = measured[index] ?? nil else {
                timedOutCount += 1
                children.append(ScanNode(
                    id: nodeID(entry.id),
                    title: entry.title,
                    subtitle: "too large to measure quickly — size unknown",
                    url: urls[0],
                    size: nil,
                    risk: entry.risk,
                    action: urls.count == 1 ? .removePath(urls[0]) : .removePaths(urls)
                ))
                continue
            }
            guard result.bytes > 0 else { continue }

            // Prefer the manager's own clean command when the tool is actually installed;
            // otherwise remove the directories, which is always available.
            var action: DeleteAction = urls.count == 1
                ? .removePath(urls[0])
                : .removePaths(urls)
            var note = entry.note

            if let clean = entry.cleanTool, let path = await ctx.shell.path(of: clean.tool) {
                action = .command(
                    executable: path,
                    args: clean.args,
                    displayName: "\(clean.tool) \(clean.args.joined(separator: " "))"
                )
                note = [entry.note, "cleaned by \(clean.tool) itself"]
                    .compactMap { $0 }.joined(separator: " · ")
            }

            children.append(ScanNode(
                id: nodeID(entry.id),
                title: entry.title,
                subtitle: [
                    (note?.isEmpty ?? true) ? nil : note,
                    result.unreadableFragment
                ].compactMap { $0 }.joined(separator: " · "),
                url: urls[0],
                size: result.bytes,
                risk: entry.risk,
                action: action
            ))
        }

        if let brew = await homebrewMaintenance(ctx) { children.append(brew) }

        return ScanNode(
            id: descriptor.id,
            title: descriptor.title,
            subtitle: "\(children.count) manager\(children.count == 1 ? "" : "s") with something cached"
                + (timedOutCount > 0 ? " · \(timedOutCount) too large to measure" : ""),
            size: children.reduce(Int64(0)) { $0 + $1.byteCount },
            risk: .safe,
            children: children
        )
    }

    /// `brew cleanup` is offered separately from the download cache, because it does more than
    /// clear downloads: it also removes superseded versions of installed formulae. Bundling that
    /// into a row labelled "cache" would be misleading, so it gets its own row that says so.
    private func homebrewMaintenance(_ ctx: ScanContext) async -> ScanNode? {
        guard let brew = await ctx.shell.path(of: "brew") else { return nil }
        return ScanNode(
            id: nodeID("brew-cleanup"),
            title: "Run brew cleanup",
            subtitle: "also removes superseded versions of installed formulae, not just downloads"
                + " · size unknown until it runs",
            size: nil,
            risk: .moderate,
            action: .command(
                executable: brew,
                args: ["cleanup", "--prune=all", "-s"],
                displayName: "brew cleanup --prune=all -s"
            )
        )
    }
}
