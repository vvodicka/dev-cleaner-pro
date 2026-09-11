# 02 — Architecture

## Stack

| Layer | Choice | Why |
|-------|--------|-----|
| Language | Swift 5.10+ (Swift 6 language mode if Xcode allows; else 5 + strict concurrency `complete`) | Native, fast FS access, no runtime |
| UI | SwiftUI (macOS 14+), `@Observable` (Observation framework), `NavigationSplitView`, `Table`/`OutlineGroup` | Small bundle, native look, no install |
| Concurrency | Swift structured concurrency (`TaskGroup`, actors) | Streaming results, cancellation |
| Persistence | `UserDefaults` (stats, settings), JSON file (custom roots) | Stateless product; minimal state |
| Process exec | `Foundation.Process` | For `xcrun simctl`, `docker`, `brew`, `npm` |
| Tests | XCTest (unit) with temp-dir fixtures | No deps |
| Dependencies | **None** | Requirement |

Sandbox: **OFF** (needs `~/Library`, `/System/Library/AssetsV2`, running CLIs). Hardened Runtime: ON. Signing: Apple Development / ad-hoc.

## Targets

```
DevCleanerPro.xcodeproj
├─ DevCleanerPro            (app, SwiftUI)
├─ DevCleanerProCore        (framework or SwiftPM local package: scanning, deletion, config — no SwiftUI)
└─ DevCleanerProCoreTests   (XCTest)
```

Prefer a **local Swift package** `Packages/DevCleanerProCore` added to the app; Claude Code can add files without touching `pbxproj` (Xcode 16+ synchronized folders also fine).

## Folder layout

```
DevCleanerPro/
├─ App/
│  ├─ DevCleanerProApp.swift          @main, WindowGroup, Settings scene
│  └─ AppState.swift             @Observable root: modules, scan state, selection, settings
├─ Features/
│  ├─ Sidebar/                   ModuleListView, ModuleRow
│  ├─ Tree/                      NodeTreeView, NodeRow, SizeBar, RiskBadge
│  ├─ Footer/                    SelectionFooter, StatsView
│  ├─ Delete/                    DeleteConfirmationSheet, DeleteProgressView
│  ├─ Settings/                  GeneralSettings, ModulesSettings, CustomRootsSettings
│  └─ Permissions/               FullDiskAccessBanner
├─ Support/
│  ├─ ByteFormatting.swift
│  └─ FinderActions.swift
Packages/DevCleanerProCore/Sources/DevCleanerProCore/
├─ Model/
│  ├─ ScanNode.swift
│  ├─ Risk.swift
│  ├─ DeleteAction.swift
│  └─ ModuleDescriptor.swift
├─ Scanning/
│  ├─ ScanModule.swift           protocol
│  ├─ ScanContext.swift          fs, shell, config, cancellation, progress
│  ├─ DirectorySizer.swift       fast allocated-size walker
│  ├─ ScanCoordinator.swift      runs modules concurrently, streams results
│  └─ Modules/                   one file per module (see 03)
├─ Deletion/
│  ├─ DeletionEngine.swift
│  ├─ PathGuard.swift            allowlist + canonicalization
│  └─ Shell.swift                Process wrapper with timeout, PATH resolution
├─ Config/
│  ├─ UserConfig.swift           Codable JSON, custom roots
│  └─ Settings.swift             UserDefaults keys
└─ Stats/
   └─ FreedStats.swift
```

## Core types

```swift
public enum Risk: String, Codable, Sendable { case safe, moderate, careful, info }

public enum DeleteAction: Sendable, Hashable {
    case removePath(URL)                       // rm / trash
    case removePaths([URL])                    // group of paths as one unit
    case command(executable: String, args: [String], displayName: String)
    case none                                  // info node
}

public struct ScanNode: Identifiable, Sendable, Hashable {
    public let id: String              // stable: "<module>/<relative-or-uuid>"
    public var title: String
    public var subtitle: String?       // "last used 2025-04-15", "iOS 26.4", "12 images"
    public var url: URL?               // for Reveal in Finder
    public var size: Int64             // bytes, allocated
    public var risk: Risk
    public var action: DeleteAction
    public var children: [ScanNode]
    public var isDeletable: Bool { action != .none }
    public var blockedReason: String?  // "Simulator is booted", "Container running"
}

public struct ModuleDescriptor: Identifiable, Sendable {
    public let id: String              // "xcode", "docker"
    public let title: String
    public let systemImage: String     // SF Symbol
    public let requiresTool: String?   // "docker", "xcrun" — module hidden if absent
    public let defaultEnabled: Bool
}

public protocol ScanModule: Sendable {
    var descriptor: ModuleDescriptor { get }
    func isAvailable(_ ctx: ScanContext) async -> Bool
    func scan(_ ctx: ScanContext) async throws -> ScanNode   // root node for the module
    func preDeleteCheck(_ node: ScanNode, _ ctx: ScanContext) async -> String? // blockedReason or nil
}
```

## Scanning

### DirectorySizer
- Uses `FileManager.enumerator(at:includingPropertiesForKeys:options:)` with keys `[.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isDirectoryKey, .isSymbolicLinkKey]`, options `[.skipsHiddenFiles: false]`, never follows symlinks (enumerator default).
- Size of a file = `totalFileAllocatedSize ?? fileAllocatedSize ?? 0`.
- API: `size(of url: URL) async throws -> Int64` and `sizedChildren(of url: URL, depth: Int) async throws -> [(URL, Int64)]` (one enumerator per child, in a `TaskGroup` with max concurrency = `ProcessInfo.activeProcessorCount`).
- Permission errors (`EPERM`, `EACCES`) are counted, not thrown; module gets `unreadableCount` in subtitle.
- Cancellation checked every 2 000 entries via `Task.checkCancellation()`.
- Note: hard-link and APFS clone double counting is accepted (same as `du`).

### ScanContext
```swift
public struct ScanContext: Sendable {
    let home: URL
    let sizer: DirectorySizer
    let shell: Shell
    let config: UserConfig
    let progress: @Sendable (String) -> Void   // status line per module
}
```

### ScanCoordinator
- `func scanAll(modules: [ScanModule]) -> AsyncStream<ModuleResult>` where `ModuleResult = (moduleID, Result<ScanNode, Error>, duration)`.
- Runs each module in its own child task; UI consumes the stream and updates `AppState.results[moduleID]`.
- Cancelling the outer task cancels all.

### Shell
- Resolve executables via login shell once at startup: `/bin/zsh -lc 'command -v docker xcrun brew npm yarn pnpm pip3 gradle'` → dictionary. Fallback candidates: `/usr/local/bin`, `/opt/homebrew/bin`, `/usr/bin`, `~/.docker/bin`.
- `run(_ exe: String, _ args: [String], timeout: Duration = .seconds(120)) async throws -> (stdout: String, stderr: String, code: Int32)`.
- Never use `sudo`. Never pass user-controlled strings unquoted into a shell — always argv arrays.

## Deletion

### PathGuard (hard safety)
- Allowed roots = union of all module roots + custom roots. Stored as canonical paths (`URL.resolvingSymlinksInPath()` + `standardizedFileURL`).
- `validate(url)` throws unless canonical `url` is **strictly inside** an allowed root and is not the root itself.
- Deny-list regardless of roots: `~`, `~/Library`, `~/Library/Keychains`, `~/Library/Application Support` (as a whole), `~/Documents`, `~/Desktop`, `/`, `/System`, `/Users`, `/Library`, any path containing `/Keychains/`.
- Refuse if `url` is a symlink whose target is outside root.

### DeletionEngine
```swift
public enum DeleteMode { case trash, permanent }
public struct DeleteOutcome { let node: ScanNode; let freed: Int64; let error: String? }

func delete(_ nodes: [ScanNode], mode: DeleteMode, ctx: ScanContext,
            onProgress: @Sendable (DeleteOutcome) -> Void) async -> [DeleteOutcome]
```
- Flatten selection to leaf-most deletable nodes (if parent and child both selected, delete parent only).
- `.removePath`: `PathGuard.validate` → `preDeleteCheck` → `trash`: `FileManager.trashItem(at:resultingItemURL:)`; `permanent`: `FileManager.removeItem(at:)`. `freed` = node.size measured before deletion.
- `.command`: run via Shell; `freed` = node.size (best effort). Commands always use argv, never `sh -c`.
- Per module: sequential. Across modules: `TaskGroup` max 3.
- Errors are collected, never abort the whole batch.
- After completion: `FreedStats.add(totalFreed)`, then coordinator rescans affected modules.

### Trash caveats
- `trashItem` on very large dirs is fast (rename) if on the same volume. Items in `/System/Library/AssetsV2` are never deletable anyway.
- Trash mode does not free space until Trash is emptied → toast says "Moved X GB to Trash — empty Trash to reclaim". Offer button "Empty Trash" that runs `osascript -e 'tell application "Finder" to empty trash'` only after explicit click.

## Config

`~/Library/Application Support/DevCleanerPro/config.json`
```json
{
  "version": 1,
  "minItemSizeMB": 50,
  "autoScanOnLaunch": true,
  "disabledModules": ["homebrew"],
  "customRoots": [
    { "id": "gemini", "title": "Gemini / Antigravity", "path": "~/.gemini", "risk": "moderate", "groupBy": "children" },
    { "id": "unity", "title": "Unity", "path": "~/Library/Unity", "risk": "moderate", "groupBy": "flat" }
  ]
}
```
- `groupBy: children` → one child node per direct subfolder; `flat` → single node.
- Missing file → defaults written on first launch. Invalid JSON → error banner, defaults used, file not overwritten.

## Settings (UserDefaults)

| Key | Type | Default |
|-----|------|---------|
| `deleteMode` | `trash`/`permanent` | `trash` |
| `autoScanOnLaunch` | Bool | true |
| `minItemSizeMB` | Int | 50 |
| `stats.totalBytesFreed` | Int64 | 0 |
| `stats.sessions` | Int | 0 |

## AppState (UI)

```swift
@Observable final class AppState {
    var modules: [ModuleDescriptor]
    var results: [String: ScanNode]         // moduleID → root
    var scanning: Set<String>
    var errors: [String: String]
    var selection: Set<ScanNode.ID>
    var deleteMode: DeleteMode
    var fdaGranted: Bool
    var isDeleting: Bool
    var deleteOutcomes: [DeleteOutcome]
    var selectedModuleID: String?
    // derived
    var selectedBytes: Int64
    var totalBytes: Int64
}
```
Selection is stored as a set of node IDs; tri-state computed from descendants. Node IDs must be stable across rescans (path-based or UUID-based, never index-based).

## UI structure

```
NavigationSplitView
├─ Sidebar: ModuleListView   (icon, title, size, spinner/error, enabled toggle in context menu)
├─ Detail:  NodeTreeView     (OutlineGroup/List with disclosure, checkbox, size bar, badge, subtitle)
Toolbar:    Rescan · Delete mode segmented · Filter (min size) · Settings
Footer:     Selected: X GB (N items) · [Clear] · [Delete…]      | Freed all-time: Y GB
Banner:     Full Disk Access missing → [Open Settings]
Sheets:     DeleteConfirmationSheet → DeleteProgressView
```

## Error handling

- Module-level errors don't fail the scan; shown as ⚠︎ in sidebar with message.
- Tool missing (`docker` not installed) → module hidden (not error).
- Tool present but daemon down (`docker system df` fails) → module shown with error "Docker is not running".

## Performance notes

- Never build per-file nodes. Modules aggregate to the depth defined in `03`.
- `DirectorySizer` results for a module are computed once per scan; children sizes reuse the same walk when possible (walk once, bucket by first path component under root).
- UI lists use `LazyVStack`/`List` with stable IDs; size bars computed from parent size, not global.
