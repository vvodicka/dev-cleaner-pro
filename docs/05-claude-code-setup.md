# 05 — Claude Code setup

## A. One-time bootstrap (human, ~5 min)

Claude Code cannot reliably create a valid `.xcodeproj` from scratch. Do this once in Xcode:

1. Xcode → File › New › Project › **macOS › App**
   - Product Name `DevCleanerPro`, Interface **SwiftUI**, Language Swift, Testing System XCTest, Storage None.
   - Save into `~/work/devcleanerpro` (git repo initialized).
2. Target `DevCleanerPro` › Signing & Capabilities:
   - Remove **App Sandbox** capability.
   - Keep Hardened Runtime. Signing: Automatic, your Development team (or "Sign to Run Locally").
3. Target › General › Minimum Deployments: **macOS 14.0**.
4. Build Settings › Swift Language Version: 6 (fallback 5 with `SWIFT_STRICT_CONCURRENCY = complete`).
5. File › New › Package… → name `DevCleanerProCore`, location `Packages/` inside repo, **Add to** DevCleanerPro project. Then target `DevCleanerPro` › General › Frameworks, Libraries → add `DevCleanerProCore`.
6. Confirm the app group in the navigator is a **synchronized folder** (Xcode 16+ default; blue folder icon). If not: right-click → Convert to Group / use "folder reference" so new files added on disk appear automatically.
7. Create folders: `docs/`, `docs/design/`. Copy `01–04` into `docs/`, design exports into `docs/design/`.
8. Add `CLAUDE.md` (section B) at repo root. Commit.
9. Verify from terminal:
   ```
   xcodebuild -project DevCleanerPro.xcodeproj -scheme DevCleanerPro -configuration Debug build | tail -5
   ```

## B. `CLAUDE.md` template

```markdown
# DevCleanerPro

macOS (14+) SwiftUI app that scans developer cache/build locations and deletes selected items (Trash or permanent). Single-user, on-demand, no background components.

## Read first
- docs/01-requirements.md — scope
- docs/02-architecture.md — types, layout, safety model (PathGuard is non-negotiable)
- docs/03-modules-spec.md — every module's roots, tree, delete strategy, risk
- docs/04-implementation-plan.md — phases; work on the phase I name, nothing else
- docs/design/ — UI reference

## Rules
- No third-party dependencies. No `sudo`. Never delete outside module roots (PathGuard).
- Core logic in Packages/DevCleanerProCore (no SwiftUI import). UI in DevCleanerPro/.
- Commands run via argv arrays through `Shell`, never `sh -c` with interpolated strings.
- Every parser gets a fixture under Packages/DevCleanerProCore/Tests/Fixtures and a unit test.
- Swift strict concurrency; types crossing tasks are Sendable.
- Use system semantic colors and SF Symbols only.
- Stable node IDs (path or UUID based). Never index-based.
- After each phase: build, run tests, update docs/CHANGELOG.md, propose commit message.

## Commands
xcodebuild -project DevCleanerPro.xcodeproj -scheme DevCleanerPro -configuration Debug build 2>&1 | tail -30
xcodebuild -project DevCleanerPro.xcodeproj -scheme DevCleanerPro test 2>&1 | tail -40
swift test --package-path Packages/DevCleanerProCore
open -a Xcode DevCleanerPro.xcodeproj

## Conventions
- One module = one file in Packages/DevCleanerProCore/Sources/DevCleanerProCore/Scanning/Modules/<Name>Module.swift, registered in ModuleRegistry.swift.
- Risk levels: safe / moderate / careful / info — see 03.
- Commit per phase or logical step; message `feat(phaseN): …`, `test: …`, `fix: …`.
- Ask before: adding a new target, changing signing, touching pbxproj.
```

## C. Kickoff prompts

### Phase 0
```
Read CLAUDE.md and docs/01–04. Implement Phase 0 from docs/04-implementation-plan.md:
core types, DirectorySizer, PathGuard, Shell, UserConfig, Settings, FreedStats in Packages/DevCleanerProCore, plus the empty NavigationSplitView app shell.
Write the unit tests listed for Phase 0. Run `swift test` and the xcodebuild build. Report what you built, test results, and any deviation from 02-architecture.md with reasons.
```

### Phase N (generic)
```
Implement Phase N from docs/04-implementation-plan.md. Constraints and module details are in docs/02 and docs/03; UI reference in docs/design. Do not touch other phases. Build, test, update CHANGELOG, summarize.
```

### Design application (Phase 6)
```
Apply the UI design in docs/design (screens + notes). Map each screen to existing SwiftUI views; adjust layout, spacing, typography, states. Use only system semantic colors. Do not change core logic. Show me a list of every view you changed and why.
```

### Adding a module later
```
Add a new scan module per docs/03 conventions: <describe roots, tree, delete strategy, risk>. Create <Name>Module.swift, register it, add fixtures/tests, verify totals against `du -sh`.
```

## D. Tips

- Let Claude Code run the app: `xcodebuild … build && open build/…/DevCleanerPro.app` — or use `open -a Xcode` and run manually for FDA/UI checks.
- For simctl/docker parsers, first capture real outputs: `xcrun simctl runtime list -j > Packages/DevCleanerProCore/Tests/Fixtures/simctl_runtime_list.json` etc.
- If Claude Code proposes SwiftPM-only app (no Xcode project) — decline; FDA attribution and app bundle need a real target.
- Mark AI-assisted code in commit/MR notes per company policy if this ever moves to a company repo.
