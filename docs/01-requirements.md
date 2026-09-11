# 01 — Requirements

## Goal

Free disk space on a developer Mac in a few minutes, on demand, with full visibility of what is deleted and why. Replace the manual `du -sh | sort -rh` + `rm -rf` workflow with a safe, fast, native GUI.

## Users

Single user (the owner). No multi-user, no onboarding beyond a Full Disk Access prompt.

## Functional requirements

### FR-1 Scan
- FR-1.1 On launch, show module list with sizes as `—` and start scanning **all enabled modules** automatically (setting: auto-scan on launch, default ON).
- FR-1.2 Scan runs concurrently per module; each module's size appears as soon as it finishes (streaming, not all-at-once).
- FR-1.3 Global progress indicator + per-module spinner. Cancellable.
- FR-1.4 "Rescan" for all modules and for a single module.
- FR-1.5 Sizes = allocated size on disk (APFS-aware), formatted `GB`/`MB` with 1 decimal.

### FR-2 Tree browsing
- FR-2.1 Each module produces a tree: module → groups → items → (optional) sub-items. Depth ≤ 4.
- FR-2.2 Every node shows: name, size, size-bar relative to parent, risk badge, optional metadata (last used / version / count).
- FR-2.3 Nodes sortable by size (default desc) or name.
- FR-2.4 "Reveal in Finder" on any node with a filesystem path.
- FR-2.5 Non-deletable info nodes (e.g. SIP-protected orphans) are rendered greyed with an ⓘ explanation.

### FR-3 Selection
- FR-3.1 Tri-state checkbox per node (off / partial / on). Checking a parent selects all deletable descendants.
- FR-3.2 Selection footer: total selected size, count of items, "Clear selection".
- FR-3.3 Quick actions per module: "Select all safe", "Select all".
- FR-3.4 Filter: hide items < N MB (default 50 MB, configurable).

### FR-4 Delete
- FR-4.1 Delete mode toggle in toolbar: **Move to Trash** (default) / **Delete permanently**.
- FR-4.2 Confirmation sheet lists every path/command that will run, grouped by module, with total size. Explicit confirm button; Permanent mode requires an additional checkbox "I understand this cannot be undone".
- FR-4.3 Items are deleted sequentially per module, modules in parallel (max 3). Progress with per-item status (✓ / ✗ + error text).
- FR-4.4 Command-based deletions (simctl, docker, brew, npm) run the tool; output captured; failure shown inline.
- FR-4.5 After deletion: rescan affected modules; show "Freed X GB" toast; add to cumulative counter.
- FR-4.6 A running/booted resource (booted simulator, running Docker container, IDE process using a cache) blocks deletion of that item with a clear message — never force.

### FR-5 Custom locations
- FR-5.1 JSON config at `~/Library/Application Support/DevCleanerPro/config.json` with user-defined roots (`path`, `title`, `risk`, `groupBy`: `children|flat`).
- FR-5.2 Settings window: list, add, remove custom roots; open config in editor.
- FR-5.3 Built-in modules can be disabled in Settings.

### FR-6 Statistics
- FR-6.1 Show cumulative bytes freed (all time) and number of cleaning sessions in the window footer / About.
- FR-6.2 Reset button.

### FR-7 Permissions
- FR-7.1 Detect missing Full Disk Access (attempt to list a protected path). Show a non-blocking banner with a button opening `System Settings → Privacy & Security → Full Disk Access`.
- FR-7.2 Scans still run without FDA; inaccessible directories are skipped and counted as "unreadable" in module metadata.

## Non-functional requirements

| ID | Requirement |
|----|-------------|
| NFR-1 | App bundle < 15 MB, cold launch < 1 s, no third-party dependencies |
| NFR-2 | Full scan of ~/Library + hidden home dirs (~500k files) < 60 s on Apple Silicon; UI stays responsive (all FS work off main actor) |
| NFR-3 | Memory < 300 MB during scan of 1M files (do not retain per-file nodes; aggregate at group level) |
| NFR-4 | Zero data loss outside selected items: canonicalize paths, forbid deletion outside allowlisted roots, never follow symlinks out of root |
| NFR-5 | Works offline; no network calls; no telemetry |
| NFR-6 | Light + Dark mode, respects system accent, keyboard navigable, resizable ≥ 900×600 |
| NFR-7 | macOS 14 Sonoma+, Apple Silicon primary (Intel not required) |
| NFR-8 | Unit-testable core: scanning and deletion engines have no SwiftUI imports |

## Out of scope (v1)

- Menu bar agent, scheduling, notifications, login item
- Deleting SIP-protected paths, anything needing `sudo`
- Duplicate finder, large-file finder across whole disk
- App uninstaller (removing `.app` bundles + leftovers)
- Historical trend charts, per-item history
- Localization

## Glossary

| Term | Meaning |
|------|---------|
| Module | Built-in scanner for one tool/area (Xcode, Docker, npm…) |
| Node | Tree element with size; may be a path node or a command node |
| Risk | `safe` (pure cache, auto-regenerated) / `moderate` (re-download or rebuild needed) / `careful` (user data or state: AVDs, volumes, backups) |
| Command node | Deleted via CLI (`xcrun simctl runtime delete <uuid>`) rather than `rm` |
