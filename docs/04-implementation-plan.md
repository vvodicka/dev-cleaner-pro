# 04 — Implementation plan

Each phase = one Claude Code session (or a few). Every phase ends with: builds clean (`xcodebuild -scheme DevCleanerPro build`), tests pass, a short `docs/CHANGELOG.md` entry. Do not start the next phase before acceptance criteria are met.

Build/test commands (put in `CLAUDE.md`):
```
xcodebuild -project DevCleanerPro.xcodeproj -scheme DevCleanerPro -configuration Debug build 2>&1 | tail -30
xcodebuild -project DevCleanerPro.xcodeproj -scheme DevCleanerPro test 2>&1 | tail -40
swift test --package-path Packages/DevCleanerProCore       # faster, core only
```

---

## Phase 0 — Skeleton (human bootstrap + Claude Code)

**Human** (see `05`): create Xcode project, disable sandbox, add local package `Packages/DevCleanerProCore`, commit.

**Claude Code**
- `DevCleanerProCore`: `ScanNode`, `Risk`, `DeleteAction`, `ModuleDescriptor`, `ScanModule`, `ScanContext`, `Shell`, `DirectorySizer`, `PathGuard`, `UserConfig`, `Settings`, `FreedStats`.
- App: `AppState`, `NavigationSplitView` with empty sidebar/detail, toolbar placeholders.
- Tests: `DirectorySizerTests` (temp dir with known file sizes → exact total; symlink not followed; EPERM dir counted as unreadable), `PathGuardTests` (inside/outside/root-itself/symlink escape/deny-list), `ShellTests` (`/bin/echo`, timeout), `UserConfigTests` (defaults, invalid JSON).

**Accept**: app launches to empty window; `swift test` green.

---

## Phase 1 — Scan pipeline + first module

- `ScanCoordinator` streaming; `AppState` consumes stream; sidebar shows modules with spinner → size.
- Module **M7 User caches** (simplest real module) and **M11 Custom locations**.
- `NodeTreeView` with disclosure, size, size bar, risk badge, subtitle, Reveal in Finder (context menu + ⌘R).
- Min-size filter (toolbar).
- FDA detection + banner.
- Cancel scan (⌘.).

**Accept**: launching scans `~/Library/Caches` in < 10 s, tree browsable, sizes match `du -sh` within 5 %.

---

## Phase 2 — Selection + deletion

- Tri-state selection; footer with selected size/count.
- `DeletionEngine` with Trash/Permanent; toolbar segmented control; UserDefaults persistence.
- `DeleteConfirmationSheet` (grouped list, total, permanent-mode acknowledgement checkbox).
- `DeleteProgressView` (per-item ✓/✗, errors), toast "Freed X GB", `FreedStats` update, auto-rescan of affected modules.
- "Empty Trash" offer after Trash-mode deletion.
- Tests: `DeletionEngineTests` with temp dirs (trash mode uses `FileManager.trashItem` into a temp volume? — for tests use permanent mode + a fake `Trasher` protocol injected), parent/child dedupe, errors collected, PathGuard denial.

**Accept**: can delete selected cache folders in both modes; nothing outside root can be deleted even if a node is hand-crafted with a bad URL (test).

---

## Phase 3 — Xcode + Simulators

- **M1 Xcode** (all groups), process check for Xcode.
- **M2 Simulators**: JSON parsing of `simctl runtime list -j` and `simctl list devices -j`; device sizes; unavailable group; runtime delete command; booted checks; orphan asset detection with info node + "Copy commands"; scan-and-mount action node.
- Fixtures: save real `simctl` JSON outputs into `Tests/Fixtures/` and parse in unit tests.

**Accept**: sidebar shows Xcode and Simulators with correct totals; deleting a DerivedData project works; runtime deletion runs the exact command and rescans.

---

## Phase 4 — Docker + Android + JetBrains

- **M3 Docker**: availability (binary + `docker info` success), parsing `--format '{{json .}}'` line-delimited output, running-container guard, image in-use detection (`docker ps -a --format '{{.Image}}'`).
- **M4 Android**: version parsing, "latest = careful" heuristic, AVD ini parsing, emulator process guard, Gradle groups.
- **M5 JetBrains**: product/version folder parsing (`^([A-Za-z]+?)(\d{4}\.\d)$`), merged 3-source tree, latest detection, IDE process guard.
- Fixtures + tests for all parsers and heuristics.

**Accept**: totals match manual `du` checks; latest versions flagged careful; deletions of an old JetBrains version remove all three folders.

---

## Phase 5 — Remaining modules

- **M6 Package caches**, **M8 AI tools**, **M9 Logs**, **M10 Backups & snapshots**.
- `tmutil` output parsing; iOS backup `Info.plist` reading (`PropertyListSerialization`).
- Cross-module dedupe in M7 (greyed "→ see Module").

**Accept**: every module from `03` present or hidden when tool/root absent; no double-counting between M7 and specialized modules.

---

## Phase 6 — Settings, polish, design conformance

- Settings scene: General (delete mode default, auto-scan, min size), Modules (enable/disable), Custom roots (add/remove path picker, open config file).
- Apply Claude Design output: spacing, typography, colors (semantic system colors only), icons, empty/loading/error states, keyboard shortcuts (⌘R rescan, ⌘⌫ delete, space toggle selection, ⌘F filter field).
- App icon (asset catalog) — generate from design.
- Stats in footer + reset in Settings › Advanced.
- Accessibility labels on checkboxes and buttons.

**Accept**: matches design within reason; VoiceOver reads tree rows; window state restored.

---

## Phase 7 — Hardening & release build

- Timeouts per module; partial results.
- Large-tree performance test: synthetic 200k-file tree scan < 15 s, memory < 300 MB (Instruments or `task_info`).
- Error copy review; every blockedReason human-readable.
- `Release` build, ad-hoc sign, copy `DevCleanerPro.app` to `/Applications`. Document in README: `xcodebuild -configuration Release archive` or simply Product › Archive › Distribute › Copy App.
- Final manual test matrix (below).

**Accept**: all rows in test matrix pass.

---

## Manual test matrix (Phase 7)

| # | Scenario | Expected |
|---|----------|----------|
| 1 | Launch without FDA | Banner shown; scans run; protected `com.apple.*` shown as protected |
| 2 | Grant FDA, rescan | Banner gone; more items sized |
| 3 | Select parent + child, delete | Only parent deleted once; freed = parent size |
| 4 | Trash mode | Items in Trash; toast offers Empty Trash |
| 5 | Permanent mode without acknowledgement | Delete button disabled |
| 6 | Booted simulator selected | Blocked with message; others proceed |
| 7 | Docker not running | Module shows error, others unaffected |
| 8 | Docker running container's image | Not selectable, reason shown |
| 9 | Cancel mid-scan | Finished modules keep results; unfinished show `—` |
| 10 | Invalid config.json | Banner, defaults used, file untouched |
| 11 | Custom root pointing to `~` | Rejected on save with message |
| 12 | Delete old JetBrains version while IDE running | Blocked for that product only |
| 13 | Orphan AssetsV2 runtimes exist | Listed as info with size and copyable commands |
| 14 | Quit during deletion | Confirmation dialog; in-flight item finishes |

---

## Definition of done (project)

- All phases accepted, tests green, no compiler warnings in `DevCleanerProCore`.
- `README.md` in repo: what it does, how to build, safety model, how to add a module (protocol + register + roots).
- Adding a new module requires: one file in `Modules/`, one line in `ModuleRegistry`, zero UI changes.
