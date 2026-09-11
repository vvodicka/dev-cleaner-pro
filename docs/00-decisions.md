# 00 — Decisions

Read this before docs 01–06. Where a spec document conflicts with this file, **this file wins**.
Every entry below was an actual contradiction or gap found while reviewing docs 01–06 against the
design and the real build environment.

## Environment reality

Docs 01–06 were written for Xcode 16 / macOS 14 and assumed a dedicated git repo bootstrapped by
hand. Actual: Xcode 26.6, Swift 6.3.3, macOS 26.6.2 (arm64), SDK macosx26.5.

## Settled decisions

| Topic | Decision | Supersedes |
|---|---|---|
| Name | **DevCleanerPro**, core package `DevCleanerProCore` | `DevSweep` throughout docs and design |
| Git | own repository rooted at `devcleaner-pro/` | doc 05 step 1 |
| `.xcodeproj` | generated, using Xcode 16+ file-system-synchronized groups | doc 05 section A (human bootstrap) |
| Deployment target | **macOS 26.0** | NFR-7 (macOS 14+) |
| Automated tests | **none**, without exception — the owner smoke-tests by hand. No test target, no test files | test requirements in every doc 04 phase, and the fixture-test rule in doc 05/B |
| Settings source of truth | **`config.json`** holds `minItemSizeMB`, `autoScanOnLaunch`, `disabledModules`, `customRoots`, `warnOnCareful`. UserDefaults holds only `deleteMode` and stats | doc 02's duplicate Config/Settings sections |
| PathGuard | `AllowedRoot { url, deletableItself: Bool }` | doc 02 "not the root itself" |
| Tree architecture | **one unified tree**; a module is a depth-0 row; the sidebar is navigation, not a filter | doc 02 `selectedModuleID`, doc 06 "tree of the selected module" |
| Min-size filter | in the toolbar **and** in Settings, alongside the design's Collapse all | — (satisfies FR-3.4 and the design) |
| Per-row size bar | **dropped** | FR-2.2, doc 06 |
| Authority | **doc 03 = module content · `docs/design/` = appearance, metrics, states, copy** | — |
| Bundle ID | `dev.vodicka.DevCleanerPro`, frozen — changing it revokes the Full Disk Access grant | — |
| Signing | stable Apple Development identity, not ad-hoc (ad-hoc changes the cdhash on every build and macOS drops the FDA grant) | doc 00 "ad-hoc / Development signing" |

## Contradictions resolved inside the spec documents

1. **PathGuard vs flat nodes.** Doc 02 requires a path be "strictly inside an allowed root **and is
   not the root itself**", but doc 03 has ~10 nodes whose deletable path *is* the module root
   (`~/Library/Caches/com.apple.dt.Xcode` M1, `~/Library/Caches/pip` M6,
   `~/Library/Logs/CoreSimulator` M9). Under doc 02's literal rule every one of those would be
   refused. Resolution: each root carries `deletableItself`; a module states explicitly which of
   its roots may be removed whole. The absolute deny-list (`~`, `~/Library`,
   `~/Library/Application Support` as a whole, `~/Documents`, `~/Desktop`, `/`, `/System`,
   `/Users`, `/Library`, `/Volumes` and `/Volumes/<name>` as a root, anything containing
   `/Keychains/`) **overrides** `deletableItself` in all cases.
2. **Risk enum.** Doc 01's glossary lists three levels, docs 02/06 four, the design names the
   middle one `rebuild`. Settled: model and JSON use `safe` / `moderate` / `careful` / `info`; the
   UI label for `moderate` is **"Rebuild"**; the JSON decoder accepts `rebuild` as an alias.
3. **Timeouts.** Doc 03 rule 1 gives 60 s per module, NFR-2 gives 60 s for the whole scan. Not a
   conflict — modules run concurrently.
4. **`cmd` nodes ignore the delete mode.** FR-4.1 offers a Trash/permanent toggle; doc 03's header
   states command nodes are always irreversible. The confirmation sheet must place them in their
   own section saying so.
5. **`/Library/Developer/CoreSimulator`** (M2) is "read only for sizing" → registered as a
   **size-only root**, never in the PathGuard allowlist.
6. **Xcode pre-delete.** Doc 03 M1 poses the question and answers itself: when Xcode or
   `xcodebuild` is running, **block** DerivedData rather than allowing it after confirmation.

## Contradictions between the design and the spec documents

| # | Conflict | Resolution |
|---|---|---|
| 7 | doc 02: sidebar filters, detail shows one module. Design: one tree across all modules, sidebar jumps and expands | **design** — `selectedModuleID` is replaced by `expanded: Set<ScanNode.ID>` plus a scroll target |
| 8 | FR-3.4 + doc 06: min-size filter in the toolbar. Design: removed, replaced by Collapse all | **both** — keep the filter, add Collapse all |
| 9 | FR-2.2 + doc 06: thin per-row size bar relative to parent. Design: no bar, 30 pt rows | **design** — right-aligned monospaced numbers carry scanability instead |
| 10 | doc 03 M7/M8 vs the design's sample data (Ollama, Saved Application State, QuickLook, font caches) | **doc 03** for content, plus three ideas adopted from the design: Ollama (`~/.ollama/models`), Saved Application State, and JetBrains `local-history` as `careful` |
| 11 | doc 03 says depth ≤ 4. Design shows 5 levels (`row inset 14 + 19 per depth level (max depth 4 = 90)`) | **design** — depth index 0–4, i.e. 5 levels |
| 12 | Design puts "Warn before deleting anything marked Careful" on the Custom locations tab | moved to **Settings › General** (it is global), stored as `warnOnCareful` |
| 13 | FR-2.3 wants sorting by size/name. Design shows Item/Risk/Size headers with no sort affordance | **Item** and **Size** headers become clickable; default size descending |
| 14 | The confirmation sheet renders `rm -rf ~/…` even though Trash mode never runs `rm` | show the real operation: permanent → `rm -rf <path>`, trash → `Move to Trash: <path>`, command nodes → the literal command |

## Corrections to the spec documents

- **FR-7.1 overstates the Full Disk Access problem.** Most target paths (`~/Library/Caches`,
  `~/Library/Developer`, `~/.gradle`, `~/.npm`) are readable without FDA. FDA is actually needed
  for `~/Library/Application Support/MobileSync/Backup` (M10) and some `com.apple.*` caches. The
  banner must name what is genuinely unmeasurable rather than warning unconditionally. Probe by
  attempting to list `~/Library/Safari`.
- **Additions taken from the design, absent from docs 01–04:** Collapse all in the toolbar ·
  Item/Risk/Size column header · Stop during scanning · Stop during deletion (doc 04 only covered
  quitting mid-deletion) · sidebar footer showing last-scan time · FDA banner opening an
  `x-apple.systempreferences:` URL · failed progress rows with a tinted background and the error
  beneath the path.

## Additions and corrections found in use (September 2026)

### Simulator "reclaimable with admin rights" — analysed properly

The 59.2 GB row is **leftover MobileAsset download payloads**, and the original wording was
right about Recovery mode but wrong about why. Established by testing on the development machine:

- Each orphan is one `.asset` directory holding a single simulator DMG, with
  `MobileAssetProperties.SimulatorVersion` naming the version (iOS 18.0–18.5, watchOS 11.0–11.4).
- They are **exactly the runtimes that were deleted**. Xcode downloads a runtime as a MobileAsset,
  CoreSimulator stages it into `/Library/Developer/CoreSimulator/Cryptex/…`, and
  `simctl runtime delete` removes the staged copy and deregisters the runtime — leaving the
  original download behind.
- `Info.plist` marks them `__AssetDefaultGarbageCollectionBehavior = NeverCollected`, so macOS
  will never reclaim them on its own.
- `mobileassetd`'s own manifest (`com_apple_MobileAsset_*.xml`) lists **2** assets while **11**
  exist on disk, so they are orphaned at the MobileAsset layer too, not just at CoreSimulator's.
- They sit on the writable Data volume (`/System/Volumes/Data`) but carry the SIP `restricted`
  flag, owned by `_nsurlsessiond`. `sudo rm` cannot touch them.
- `assetutil` is unrelated — it handles `.car` asset catalogues.
- **`simctl runtime scan-and-mount` makes it worse.** It does adopt the orphans, but
  asynchronously (it returns in 0.1 s and finishes minutes later) and it *stages a second copy*
  into the Cryptex store rather than adopting the original in place. Net effect: the data exists
  twice and the orphan remains. The maintenance row now says so.
- `simctl` *can* delete inside SIP-protected `AssetsV2` — it did so for two referenced assets —
  but only for runtimes whose storage is the asset itself ("Patchable Cryptex Disk Image").
  An adopted orphan is never of that kind.

Conclusion: Recovery mode really is the only route, and each orphan row now carries its exact
`sudo rm -rf <path>` for use from there.

### simctl is asynchronous

`runtime delete` and `scan-and-mount` both return as soon as the daemon accepts the request.
Deleting nine runtimes took over a minute to settle. Rescanning immediately therefore reads the
old state and the deleted items reappear — which is exactly what was reported. After a
command-driven deletion the app now waits 3 s, rescans, then rescans again 12 s later.

### Locations added

From surveying the disk and from published guides:

- **Project build output** (new module, **72.4 GB** on the development machine): `node_modules`,
  Unity `Library`, `Pods`, `target`, `.venv`, `.next`, `vendor` and a dozen more, found inside
  the user's own code folders. Search roots are top-level home folders that contain a git
  repository — chosen over a fixed list of names like `~/Developer` because the development
  machine keeps its code in `~/others`, which no such list would guess.
- **Container runtimes** (new module): OrbStack, Colima, Podman, Lima, Rancher Desktop, Vagrant,
  VirtualBox, UTM.
- **Package caches**: SwiftPM (506 MB here), TypeScript, rbenv, rustup, Electron, Cypress,
  conda, SDKMAN, Julia, RubyGems, SonarLint, Playwright-for-Go.

Deliberately **not** added: `~/Library/Group Containers` and `~/Library/Containers`. The largest
entries there are application data (5.9 GB of WhatsApp), not developer caches, and the guidance
is consistent that they should be managed through the owning app rather than by hand.

### Hard links must be counted once — doc 02's premise was wrong

Doc 02 stated that "hard-link and APFS clone double counting is accepted (same as `du`)". `du`
does not double count hard links; it remembers the inode of any file with more than one link and
counts it once.

The consequence was found by investigating why a React Native `node_modules` reported 26.3 GB:

- `du` said 13.9 GB for the same directory.
- Every size API agreed with each other and with `st_blocks` at 26.28 GB when summed per *path*.
- Grouping by inode showed **92 inodes reachable from nine paths each** — mostly
  `libreactnative.so` at ~150 MB a copy, hard-linked across `android/build` directories of
  different packages. That accounted for exactly the 12.38 GB difference.

For an app whose only job is saying how much space you will get back, promising 12 GB that
deleting the folder cannot return is the worst kind of wrong. `DirectorySizer` now remembers the
`(device, inode)` of files with a link count above one and counts each once — the same
optimisation `du` makes, and the reason memory stays flat on large trees. Device as well as inode,
because inode numbers are unique only within a volume and a custom location can live on another
disk.

APFS clones are deliberately still counted per copy: once written to, each clone occupies its own
blocks, and `du` reports them the same way.

The correction moved the Project build output module from 72.4 GB to 59.9 GB. Every other module
was unaffected, having no hard links to speak of.
