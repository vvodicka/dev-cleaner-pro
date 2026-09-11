# Manual test matrix

Doc 04's 14 scenarios, with what was verified automatically and what still needs a person.

Automated coverage comes from `swift run dcp-scan --self-check` (91 checks, deletes nothing) and
from `swift run dcp-scan` compared against `du -sh`. **Deletion was never executed** — the owner
asked for that to stay manual, so every row involving an actual delete is marked accordingly.

| # | Scenario | Expected | Status |
|---|---|---|---|
| 1 | Launch without Full Disk Access | Banner shown, scans still run, protected `com.apple.*` shown as protected | **Verified live.** FDA is not granted on the build machine. 14 protected cache folders detected, exactly matching `du`'s 14 "Operation not permitted" entries. `MobileSync/Backup` correctly reports it cannot be read. |
| 2 | Grant FDA, rescan | Banner gone, more items sized | **Needs a person.** Granting FDA cannot be scripted. |
| 3 | Select parent and child, delete | Parent deleted once, freed = parent size | **Logic verified**, execution manual. Self-check confirms one target on the parent, size counted once, plan lists one item. |
| 4 | Trash mode | Items in Trash, toast offers Empty Trash | **Needs a person.** Wording and the 8 s toast are in place; `trashItem` is not exercised. |
| 5 | Permanent mode without acknowledgement | Delete button disabled | **Needs a person** for the visual. The gate is `canProceed` in `DeleteConfirmSheet`, extended by `warnOnCareful` to Trash mode when user data is selected. |
| 6 | Booted simulator selected | Blocked with a message, others proceed | **Partially verified.** No simulator was booted on the build machine, so the live path is untested. The equivalent shape *is* live-verified through Docker: 6 in-use images are blocked with a reason. `preDeleteCheck` re-queries `simctl` immediately before deletion. To test: `xcrun simctl boot <udid>`, rescan, then shut it down again. |
| 7 | Docker not running | Module shows an error, others unaffected | **Needs a person.** Docker was running throughout. The path throws `ScanFailure` with "Docker is installed but not running", which the sidebar shows as ⚠︎; a failing module cannot fail the scan by construction (`ScanCoordinator` turns every module error into a `.failure` result). |
| 8 | Docker running container's image | Not selectable, reason shown | **Verified live.** 6 of 76 images blocked with "A container is using this image — remove the container first". |
| 9 | Cancel mid-scan | Finished modules keep results, unfinished show — | **Needs a person** for the visual. `cancelScan` cancels the task; `results` is only written per module on success, so finished modules are untouched. |
| 10 | Invalid `config.json` | Banner, defaults used, file untouched | **Verified.** Self-check writes broken JSON, confirms the error is reported, defaults are used, and the file is byte-identical afterwards. Also covers partial files and a save/reload round trip. |
| 11 | Custom root pointing at `~` | Rejected on save with a message | **Verified.** `~`, `~/Documents`, `~/Library`, `/`, `/System/Library`, relative paths and non-existent folders are all refused; an ordinary folder is accepted. |
| 12 | Delete old JetBrains version while an IDE runs | Blocked for that product only | **Needs a person.** `preDeleteCheck` matches the running process name against the node ID, so one open IDE does not lock the other four. |
| 13 | Orphaned AssetsV2 runtimes exist | Listed as info with size and copyable commands | **Verified live.** 9 orphans, 59.2 GB, cross-checked as 86.6 GB total AssetsV2 minus 27.4 GB referenced. Info rows, no checkbox, "Copy commands" in the context menu, and the row states that SIP means not even `sudo` reaches them. |
| 14 | Quit during deletion | Confirmation dialog, in-flight item finishes | **Implemented in this phase** — the matrix caught that it was missing. `TerminationGuard` intercepts termination while `isDeleting`, offers "Stop and Quit" or "Keep Deleting", and on Stop defers termination until the current item completes. **Needs a person** to confirm the dialog. |

## Non-functional requirements

| ID | Requirement | Measured |
|---|---|---|
| NFR-1 | Bundle under 15 MB, cold launch under 1 s, no dependencies | **5.8 MB**, process up in **0.09 s**, zero dependencies ✓ |
| NFR-2 | ~500 k files under 60 s, UI responsive | **Not met on this machine: 63 s.** One directory is responsible — `~/.cocoapods/repos` holds 1 819 272 files and `du` alone needs 42 s on it. Every other module finishes inside 30 s. See the Phase 5 changelog entry for the `getattrlistbulk` experiment and why it was abandoned. Filesystem work runs on a dedicated queue, so the UI stays responsive regardless. |
| NFR-3 | Under 300 MB during a large scan | **100.7 MB** peak while scanning 483 GB across all ten modules ✓ |
| NFR-4 | No data loss outside the selection | `PathGuard` verified by 60+ checks, including symlink escape against the real filesystem ✓ |
| NFR-5 | Works offline, no network, no telemetry | No networking code, no network entitlements ✓ |
| NFR-6 | Light and dark, keyboard navigable, resizable ≥ 900×600 | Semantic colours throughout, twelve asset-catalog badge colours with both variants, `minWidth: 900, minHeight: 600` ✓. Appearance not visually verified — see below. |
| NFR-7 | macOS 14+ | Superseded: macOS 26 by decision (`docs/00-decisions.md`) |
| NFR-8 | Core unit-testable, no SwiftUI import | `DevCleanerProCore` never imports SwiftUI ✓ |

## Not verified

**Pixel conformance to the design.** The build terminal has no Screen Recording permission, so no
screenshot could be taken to compare against frames 1a–1j. Metrics, colour roles, states and copy
were implemented from the component spec, but whether it *looks* right is unconfirmed.

**Anything that deletes.** By instruction. `dcp-scan --self-check` exercises `PathGuard` and the
plan logic without touching the filesystem beyond its own scratch folder.
