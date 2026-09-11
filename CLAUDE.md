# DevCleanerPro

macOS (26+) SwiftUI app that scans developer cache/build locations and deletes selected items
(Trash or permanent). Single-user, on-demand, no background components, no network, no telemetry.

## Read first

- `docs/00-decisions.md` — **read before docs 01-06.** Resolves every contradiction between the
  spec documents and the design. Where a spec document conflicts with this file, this file wins.
- `docs/01-requirements.md` — scope
- `docs/02-architecture.md` — types, layout, safety model (PathGuard is non-negotiable)
- `docs/03-modules-spec.md` — **authoritative for module content**: roots, tree shape, delete
  strategy, risk per module
- `docs/04-implementation-plan.md` — phases; work on the phase named, nothing else
- `docs/design/` — **authoritative for appearance**: metrics, states, copy, interaction rules.
  `DevSweep.dc.html` holds 10 frames + the component spec; `DevSweepWindow.dc.html` is the
  parametric main-window component (theme x mode x state x module x banner) with working
  tri-state selection logic worth reading before implementing selection. `docs/design/_ds/` is
  the corporate design system the canvas was authored in — present locally, deliberately
  untracked, never published and never part of the app.

## Rules

- No third-party dependencies. No `sudo`. Never delete outside module roots (PathGuard).
- Core logic in `Packages/DevCleanerProCore` (never `import SwiftUI`). UI in `DevCleanerPro/`.
- Commands run via argv arrays through `Shell`, never `sh -c` with interpolated strings.
- Swift 6 strict concurrency; types crossing tasks are `Sendable`.
- **System semantic colors only.** The single exception is the four risk badge hues, which live in
  the asset catalog as `RiskSafe` / `RiskRebuild` / `RiskCareful` / `RiskInfo` with Light/Dark
  variants. Red and navy in the design mockups are stand-ins for `.controlAccentColor` and system
  backgrounds — never hard-code them.
- SF Symbols only for icons. Every number gets `.monospacedDigit()`.
- Stable node IDs (path or UUID based). Never index-based.
- **No automated tests at all** — the owner smoke-tests by hand. Do not add a test target, a test
  file, or a `swift test` step. Verify sizes against `du -sh` and parsers against real captured
  output in `docs/samples/`.
- After each phase: build, run the app, compare against the matching design frame in Light and
  Dark, update `docs/CHANGELOG.md`, propose a commit message.

## Commands

```
xcodebuild -project DevCleanerPro.xcodeproj -scheme DevCleanerPro -configuration Debug build 2>&1 | tail -30
swift build --package-path Packages/DevCleanerProCore
open build/Debug/DevCleanerPro.app
du -sh <path>                        # reference when verifying sizes

scripts/release.sh <version> [--install|--publish|--skip-notarize]
scripts/update-cask.sh <version>     # after --publish
```

Release signing, notarization and the Homebrew tap: `docs/RELEASING.md`.

## Conventions

- One module = one file in
  `Packages/DevCleanerProCore/Sources/DevCleanerProCore/Scanning/Modules/<Name>Module.swift`,
  registered with one line in `ModuleRegistry.swift`, zero UI changes.
- Risk levels in code and JSON: `safe` / `moderate` / `careful` / `info`. The UI label for
  `moderate` is **"Rebuild"**.
- View names follow the design's component spec (`MainWindowView`, `ModuleJumpList`, `ScanTreeView`,
  `ItemRow`, `TriStateToggle`, `RiskBadge`, ...). Do not invent parallel names.
- Commit per phase or logical step: `feat(phaseN): ...`, `fix: ...`, `docs: ...`.
- Ask before: adding a target, changing signing, changing the bundle ID (breaks the Full Disk
  Access grant), editing `project.pbxproj`.
