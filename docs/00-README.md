# DevCleanerPro — macOS developer disk cleaner

Personal, on-demand macOS app that scans known developer/cache locations, shows what occupies space as an expandable tree, and lets the user delete selectively (to Trash or permanently). Not a background app — launch, clean, quit.

Working name: **DevCleanerPro** (rename freely; grep `DevCleanerPro` in docs).

## Document set

| # | File | Purpose | Reader |
|---|------|---------|--------|
| 01 | `01-requirements.md` | Scope, functional + non-functional requirements, out of scope | Human + Claude Code |
| 02 | `02-architecture.md` | Tech stack, project layout, core types, concurrency, deletion engine, config, safety | Claude Code |
| 03 | `03-modules-spec.md` | Every scan module: paths, detection, tree shape, delete strategy, risk level | Claude Code |
| 04 | `04-implementation-plan.md` | Phased milestones with acceptance criteria and tests | Claude Code |
| 05 | `05-claude-code-setup.md` | One-time Xcode project bootstrap (human), `CLAUDE.md` template, kickoff prompts | Human + Claude Code |
| 06 | `06-claude-design-prompt.md` | Prompt for Claude Design to produce the first UI design | Human → Claude Design |

## Recommended flow

1. Run `06` in Claude Design → iterate → export screens (PNG/Figma) + component notes.
2. Do the one-time bootstrap in `05` (create Xcode project, ~5 min).
3. Put docs `01–04` + design exports into `docs/` in the repo, add `CLAUDE.md` from `05`.
4. Start Claude Code with kickoff prompt from `05`, work phase by phase (`04`).

## Key decisions (already made)

| Topic | Decision |
|-------|----------|
| Stack | Swift 5.10+, SwiftUI, macOS 14+, no third-party dependencies |
| Delete mode | Both: Move to Trash / Permanent, toggle in UI (default Trash) |
| Persistence | Stateless scans; only cumulative "bytes freed" counter in UserDefaults |
| Lifecycle | Regular windowed app, no menu bar agent, no scheduler, no login item |
| Config | Editable JSON for custom paths; built-in modules in code |
| Distribution | Local build, ad-hoc / Development signing, no App Store, no sandbox |
| Privileges | User-level only. Never `sudo`. SIP-protected orphans are shown read-only with instructions |
| UI language | English |
