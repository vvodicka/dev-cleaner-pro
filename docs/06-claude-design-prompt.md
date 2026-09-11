# 06 — Claude Design prompt

Paste everything below the line into Claude Design. Attach nothing else; iterate afterwards.

---

Design a native **macOS desktop app UI** called **DevCleanerPro** — a personal developer disk cleaner (think DevCleaner / DaisyDisk, but tailored for one developer). It scans known developer locations (Xcode DerivedData, iOS simulators & runtimes, Docker images/volumes, Android SDK/AVDs, JetBrains IDE caches, npm/yarn/pip/gradle caches, ~/Library/Caches, AI-tool caches, logs, iOS backups) and lets the user delete selected items either to Trash or permanently.

## Product constraints
- Native macOS 14+ look: SwiftUI, `NavigationSplitView`, system fonts (SF Pro), SF Symbols, semantic system colors, system accent color. Must work in Light and Dark mode.
- Single window, resizable, min 900×600. No menu-bar agent, no onboarding wizard.
- Everything must be implementable in plain SwiftUI without custom drawing beyond simple bars/badges.
- English UI, terse labels.

## Layout (one main screen)
1. **Toolbar**: Rescan (⌘R) · Delete mode segmented control [Move to Trash | Delete permanently] · Min size filter (menu: 0 / 50 MB / 200 MB / 1 GB) · Settings.
2. **Sidebar** (left, ~240 pt): list of modules with SF Symbol icon, name, total size right-aligned; states: scanning (spinner), done, error (⚠︎ with tooltip), hidden/disabled (context menu). Modules: Xcode, Simulators, Docker, Android, JetBrains, Package caches, User caches, AI tools, Logs, Backups & snapshots, Custom locations.
3. **Detail** (right): expandable **tree** of the selected module, depth up to 4. Each row: disclosure chevron · tri-state checkbox · title · optional subtitle (e.g. "last used Apr 15 2025", "iOS 26.4", "12 images") · risk badge · size (monospaced digits) · thin horizontal size bar relative to parent. Row context menu: Reveal in Finder, Select all safe, Copy path/command. Some rows are **info-only** (greyed, ⓘ, no checkbox) with an explanation popover and a "Copy commands" button. Some rows are **blocked** (e.g. "Simulator is booted") — checkbox disabled with reason on hover.
4. **Footer bar** (persistent): left "Selected: 12.4 GB · 37 items" + "Clear"; center-right primary button "Delete…" (destructive style when mode = permanent); far right small text "Freed all-time: 612 GB".
5. **Banner** (top of detail, dismissible): "Full Disk Access not granted — some folders can't be measured." with button "Open System Settings".

## Secondary screens / sheets
- **Delete confirmation sheet**: grouped list by module of every path / shell command to be executed, each with size; total at top; in permanent mode an acknowledgement checkbox "I understand this can't be undone" gating the destructive button.
- **Delete progress sheet**: list with per-item status ✓ / ✗ + error text, overall progress, "Done" → closes and shows a transient toast "Freed 12.4 GB" (Trash mode: "Moved 12.4 GB to Trash" + secondary button "Empty Trash").
- **Settings window** (tabs): General (default delete mode, auto-scan on launch, min item size), Modules (enable/disable list), Custom locations (table: title, path, risk; add via folder picker; "Open config file"), Advanced (reset stats).
- **States**: empty (before first scan), scanning (per-module progress, partial results visible), no results above filter, error in module.

## Risk badges
Four levels as small capsule tags: **Safe** (green), **Rebuild** (yellow/orange, "moderate" — re-download or rebuild needed), **Careful** (red — user data/state), **Info** (grey, not deletable). Keep them subtle; color + short label, not color alone.

## Visual direction
Utilitarian, calm, data-dense but readable; no illustrations, no gradients. Emphasize scanability of sizes (right-aligned monospaced numbers, bars). Destructive actions clearly distinguished only where it matters. Comparable polish to Apple's Disk Utility / Activity Monitor.

## Deliverables
1. Main window in Light and Dark mode, module "Xcode" selected with realistic sample data (DerivedData with 6 projects, Archives, iOS DeviceSupport, Caches).
2. Main window with module "Simulators" showing runtimes, devices grouped by runtime, an "Unavailable" group, a blocked booted device, and the info-only "Orphaned runtime assets" group.
3. Delete confirmation sheet (permanent mode) and delete progress sheet with one failed item.
4. Settings › Custom locations tab.
5. Empty/first-launch state and scanning state.
6. App icon concept (broom/sweep + disk motif, macOS squircle).
7. A short **component spec** page: spacing scale, row height, badge styles, typography sizes, color roles mapped to SwiftUI semantic colors (`.primary`, `.secondary`, `Color(nsColor: .controlAccentColor)`, `.red`, etc.), and a list of screens → SwiftUI view names.

Sample data to use (realistic): Xcode 24.1 GB, Simulators 63.9 GB, Docker 44.2 GB, Android 23.0 GB, JetBrains 17.3 GB, Package caches 31.6 GB, User caches 14.0 GB, AI tools 8.9 GB, Logs 1.8 GB, Backups 0 B. Freed all-time 449 GB.
