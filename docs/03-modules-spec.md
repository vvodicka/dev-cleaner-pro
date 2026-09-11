# 03 — Scan modules specification

Conventions
- `~` = user home. All paths are module roots for `PathGuard`.
- **Tree** column shows depth: `Module → Group → Item → Sub-item`.
- **Delete** column: `rm` = removePath (Trash/permanent per mode); `cmd` = command node (mode toggle ignored, always permanent — UI shows a small ⚡ icon on such nodes).
- Risk: `safe` / `moderate` / `careful` / `info`.
- Items below `minItemSizeMB` are hidden but still counted in parent size.

Module order in sidebar = order below (by typical size impact).

---

## M1 · Xcode  `hammer`

| Group | Root | Tree | Detection / metadata | Delete | Risk |
|-------|------|------|----------------------|--------|------|
| Derived Data | `~/Library/Developer/Xcode/DerivedData` | Group → per project folder (title = folder name minus trailing `-<hash>`); `ModuleCache.noindex`, `SDKStatCaches.noindex`, `SymbolCache.noindex` shown as separate items | subtitle = last modified date | `rm` | moderate |
| Archives | `~/Library/Developer/Xcode/Archives` | Group → per date folder → per `.xcarchive` (title = archive name, subtitle = date) | | `rm` | careful |
| iOS DeviceSupport | `~/Library/Developer/Xcode/iOS DeviceSupport` (+ `watchOS DeviceSupport`, `tvOS DeviceSupport`) | Group → per version folder | Mark highest version per platform as `moderate`, others `safe` | `rm` | safe/moderate |
| Previews | `~/Library/Developer/Xcode/UserData/Previews` | flat | | `rm` | safe |
| Xcode Caches | `~/Library/Caches/com.apple.dt.Xcode` | flat | | `rm` | safe |
| Products / Index | `~/Library/Developer/Xcode/Products`, `~/Library/Developer/Xcode/Index` (if exist) | flat each | | `rm` | safe |
| Documentation cache | `~/Library/Developer/Shared/Documentation/DocSets` (if exists) | flat | | `rm` | moderate |

Pre-delete check: if `xcodebuild` or `Xcode` process is running, show blockedReason "Quit Xcode first" for DerivedData only (soft: still allow after confirmation? → **No**, block.)

---

## M2 · Simulators  `iphone`

Tool: `xcrun`. Root paths: `~/Library/Developer/CoreSimulator`, `/Library/Developer/CoreSimulator` (read only for sizing), `/System/Library/AssetsV2/com_apple_MobileAsset_*SimulatorRuntime` (info only).

| Group | Source | Tree | Metadata | Delete | Risk |
|-------|--------|------|----------|--------|------|
| Runtimes | `xcrun simctl runtime list -j` | Group → per runtime (title `iOS 26.4 (23E244)`) | subtitle `last used <date> · <size>`; size from JSON `sizeBytes`; `state != Ready` marked | `cmd xcrun simctl runtime delete <identifier>` | moderate; the newest per platform = careful |
| Devices | `xcrun simctl list devices -j` + sizes of `~/Library/Developer/CoreSimulator/Devices/<UDID>` | Group → per runtime → per device | subtitle = state (Booted/Shutdown) + data size; **unavailable** devices grouped under "Unavailable (runtime missing)" | device: `cmd xcrun simctl delete <UDID>`; unavailable group: `cmd xcrun simctl delete unavailable` | devices: moderate; unavailable: safe |
| Device caches | `~/Library/Developer/CoreSimulator/Caches` | flat | | `rm` | safe |
| Orphaned runtime assets | Enumerate `/System/Library/AssetsV2/com_apple_MobileAsset_iOSSimulatorRuntime/*.asset` and `..._watchOSSimulatorRuntime/*.asset` etc.; compare with `Image Path` / `Parent Image Path` from `simctl runtime list -v` (parse verbose text or `-j`). Any `.asset` not referenced → orphan | Group → per orphan asset (title = `<platform> asset <hash-prefix>`, subtitle = created date) | Info text on group: "Protected by SIP. Free X GB by: `xcrun simctl runtime scan-and-mount` then `xcrun simctl runtime delete <id>`; if still present, requires Recovery mode (csrutil disable → rm → csrutil enable)." Provide **Copy commands** button. | `none` | info |
| Scan & mount orphans | — | Action node "Try `scan-and-mount`" | Runs `xcrun simctl runtime scan-and-mount`, then rescans module | `cmd` | safe |

Pre-delete: booted device → blocked "Shut down simulator first". Runtime with a booted device → blocked.

---

## M3 · Docker  `shippingbox`

Tool: `docker` (module hidden if missing; error state if daemon not running). Also size root `~/Library/Containers/com.docker.docker` for total (info).

| Group | Source | Tree | Metadata | Delete | Risk |
|-------|--------|------|----------|--------|------|
| Images | `docker images --format '{{json .}}'` + `docker system df -v` | Group → per image (`repo:tag`), dangling under sub-group "Dangling" | subtitle = created, `in use by N containers` | `cmd docker image rm <id>` (dangling group: `docker image prune -f`) | in-use: blocked; unused: moderate; dangling: safe |
| Containers (stopped) | `docker ps -a --format '{{json .}}'` | Group → per stopped container | subtitle = image, exited date | `cmd docker rm <id>` | moderate |
| Volumes (unused) | `docker volume ls -f dangling=true --format '{{json .}}'` + `df -v` sizes | Group → per volume | | `cmd docker volume rm <name>` | careful |
| Build cache | `docker system df` (Build Cache line) | single node | | `cmd docker builder prune -af` | safe |
| Docker Desktop VM disk | `~/Library/Containers/com.docker.docker/Data/vms/*/data/Docker.raw` | info node | "Shrinks automatically after prune; or Docker Desktop → Troubleshoot → Clean/Purge data" | `none` | info |

Running containers are listed under a greyed "Running (not deletable)" group.

---

## M4 · Android  `smartphone` (SF: `candybarphone` fallback `iphone.gen1`)

Roots: `~/Library/Android/sdk`, `~/.android`, `~/.gradle`.

| Group | Root | Tree | Metadata | Delete | Risk |
|-------|------|------|----------|--------|------|
| NDK | `sdk/ndk` | Group → per version | highest version = careful | `rm` | moderate |
| System images | `sdk/system-images` | Group → per `android-XX` → per ABI/variant | highest API = careful | `rm` | moderate |
| Build tools | `sdk/build-tools` | Group → per version | highest = careful | `rm` | moderate |
| Platforms | `sdk/platforms` | Group → per `android-XX` | highest = careful | `rm` | moderate |
| Emulator | `sdk/emulator` | flat | | `rm` | careful |
| AVDs | `~/.android/avd/*.avd` (+ matching `.ini`) | Group → per AVD (title from `.ini` `avd.ini.displayname` or folder) | subtitle = target API, last modified | `rm` (avd folder + ini as `removePaths`) | careful |
| Gradle caches | `~/.gradle/caches` | Group → children (`modules-2`, `transforms-*`, `jars-*`, `build-cache-*`) | | `rm` | safe |
| Gradle daemon logs / wrapper dists | `~/.gradle/daemon`, `~/.gradle/wrapper/dists` | Group → per version | | `rm` | safe / moderate |
| Android Studio caches | `~/Library/Caches/Google/AndroidStudio*` | Group → per version | | `rm` | safe |

Pre-delete: `emulator` or `qemu-system` process running → block AVD deletion.

---

## M5 · JetBrains  `j.square` (fallback `curlybraces.square`)

Roots: `~/Library/Caches/JetBrains`, `~/Library/Application Support/JetBrains`, `~/Library/Logs/JetBrains`.

| Group | Tree | Metadata | Delete | Risk |
|-------|------|----------|--------|------|
| Per IDE version (merged view) | Group → per product (WebStorm, Rider, PyCharm, DataGrip…) → per version (`2025.3`) → three sub-items: Caches / Application Support / Logs | Detect **latest installed version** per product by parsing folder names (`<Product><YYYY.N>`); latest = careful, older = safe. subtitle = "latest" / "old version" | version node: `removePaths([caches, appSupport, logs])`; sub-item: `rm` | old: safe; latest Caches: safe; latest App Support: careful (contains plugins/settings) |
| Toolbox | `~/Library/Caches/JetBrains/Toolbox`, `~/Library/Application Support/JetBrains/Toolbox` | flat | | `rm` (Caches only; App Support blocked) | safe |

Pre-delete: any JetBrains IDE process running (`pgrep -f "JetBrains|WebStorm|Rider|PyCharm|DataGrip"`) → block Caches/Support of that product with "Quit <Product> first".

---

## M6 · Package manager caches  `archivebox`

One node per manager; hidden if root missing.

| Item | Root / source | Size | Delete | Risk |
|------|---------------|------|--------|------|
| npm | `~/.npm/_cacache` (size of `~/.npm`) | rm root | `cmd npm cache clean --force` (fallback `rm ~/.npm/_cacache`) | safe |
| Yarn | `~/Library/Caches/Yarn`, `~/.yarn/berry/cache` | | `rm` | safe |
| pnpm | `~/Library/Caches/pnpm`, `~/Library/pnpm/store` | | `cmd pnpm store prune` if available, else `rm` cache only | safe |
| pip | `~/Library/Caches/pip` | | `rm` | safe |
| uv | `~/.cache/uv` | | `cmd uv cache clean` if available else `rm` | safe |
| CocoaPods | `~/Library/Caches/CocoaPods`, `~/.cocoapods/repos` (repos = moderate) | | `rm` | safe / moderate |
| Homebrew | `~/Library/Caches/Homebrew` | | `cmd brew cleanup --prune=all -s` (also removes old versions; show note) + `rm` cache node | safe |
| node-gyp | `~/Library/Caches/node-gyp` | | `rm` | safe |
| Go | `$(go env GOCACHE)` if `go` present | | `cmd go clean -cache -modcache` (modcache = moderate, separate node) | safe / moderate |
| Cargo | `~/.cargo/registry/cache`, `~/.cargo/git` | | `rm` | moderate |
| Puppeteer / Playwright | `~/.cache/puppeteer`, `~/Library/Caches/ms-playwright*` | | `rm` | moderate |
| .NET | `~/.nuget/packages`, `~/.dotnet` (dotnet careful) | | `rm` | moderate / careful |
| Composer / Bundler | `~/.composer/cache`, `~/.bundle/cache` | | `rm` | safe |

---

## M7 · User caches  `internaldrive`

Root: `~/Library/Caches`.

- Tree: Group → per top-level folder (bundle id or name). Exclude items already covered by other modules (Xcode, JetBrains, Homebrew, Yarn, pip, pnpm, Google/AndroidStudio) — show them greyed with "→ see <Module>" and no checkbox, to keep the total honest.
- `com.apple.*` items that return EPERM are listed as "protected" info nodes with size unknown.
- Delete: `rm` per item. Risk: safe.
- Quick action: "Select all deletable".

---

## M8 · AI tools  `sparkles`

| Item | Root | Tree | Delete | Risk |
|------|------|------|--------|------|
| Claude Desktop | `~/Library/Application Support/Claude` | children `vm_bundles`, `Cache`, `Code Cache`, `GPUCache`, `claude-code-vm` deletable; everything else info | `rm` | vm_bundles/Cache: safe; claude-code-vm: moderate |
| Claude Desktop caches | `~/Library/Caches/com.anthropic.claudefordesktop*` | flat | `rm` | safe |
| Claude Code | `~/.claude` → children `projects` (conversation logs, careful), `debug`, `cache`, `statsig`, `todos` | per child | `rm` | debug/cache: safe; projects: careful |
| Gemini / Antigravity | `~/.gemini`, `~/.antigravity`, `~/Library/Application Support/Antigravity` | per child | `rm` | moderate |
| Copilot | `~/.cache/github-copilot` | flat | `rm` | safe |
| Cursor / VS Code caches | `~/Library/Application Support/{Cursor,Code}/{Cache,CachedData,CachedExtensionVSIXs,Code Cache,GPUCache}` | per app → per cache dir | `rm` | safe |

---

## M9 · Logs & diagnostics  `doc.text.magnifyingglass`

| Item | Root | Tree | Delete | Risk |
|------|------|------|--------|------|
| User logs | `~/Library/Logs` | Group → per folder | `rm` | safe |
| Diagnostic reports | `~/Library/Logs/DiagnosticReports` | flat | `rm` | safe |
| CoreSimulator logs | `~/Library/Logs/CoreSimulator` | flat | `rm` | safe |

---

## M10 · Backups & snapshots  `clock.arrow.circlepath`

| Item | Source | Tree | Delete | Risk |
|------|--------|------|--------|------|
| iOS device backups | `~/Library/Application Support/MobileSync/Backup/<UDID>` | Group → per backup; title from `Info.plist` `Device Name`, subtitle `Last Backup Date`, `Product Version` | `rm` | careful |
| Time Machine local snapshots | `tmutil listlocalsnapshots /` | Group → per snapshot (date). Size unknown → subtitle "size n/a" | `cmd tmutil deletelocalsnapshots <date>` | moderate |

---

## M11 · Custom locations  `folder.badge.gearshape`

From `config.json customRoots`. Each root → node; `groupBy: children` → child nodes per subfolder. Risk from config. Delete `rm`. Title from config.

---

## Common rules

1. Every module returns within 60 s or reports partial results with subtitle "partial (timeout)".
2. Every deletable path must lie under one of the module's declared roots (enforced by `PathGuard`, roots registered by module at startup).
3. "Latest version" heuristics compare with `String.compare(options: .numeric)`.
4. Command nodes display the exact command in the confirmation sheet.
5. Empty groups (size 0 or no children after filter) are hidden.
6. Module subtitle in sidebar: total size + `N unreadable` if any.
