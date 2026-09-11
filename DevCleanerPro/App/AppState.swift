import Foundation
import Observation
import AppKit
import DevCleanerProCore

/// Root observable state for the single window.
///
/// Shaped around the design's one-unified-tree architecture rather than doc 02's
/// `selectedModuleID`: modules are the depth-0 rows of a single tree, the sidebar navigates
/// instead of filtering, and the footer totals across modules. So expansion and a scroll target
/// replace the notion of a "selected module" (`docs/00-decisions.md` #7).
@Observable
@MainActor
final class AppState {
    // MARK: - Modules and results

    /// Installed, enabled modules in sidebar order.
    var modules: [ModuleDescriptor] = []
    /// moduleID → the module's depth-0 node, as it finishes scanning.
    var results: [String: ScanNode] = [:]
    /// Module IDs currently being measured — drives the per-row spinner.
    var scanning: Set<String> = []
    /// Modules that ran and found nothing, so they are not in the sidebar. Kept so the window
    /// can say they exist — otherwise a module that is working perfectly looks like one that is
    /// missing, and there is nowhere to go to find out.
    var emptyModules: [ModuleDescriptor] = []
    /// moduleID → message, for the ⚠︎ in the sidebar. A module error never fails the scan.
    var errors: [String: String] = [:]
    /// Per-module status line while scanning.
    var statusLines: [String: String] = [:]

    // MARK: - Tree state

    var selection = SelectionModel()
    var expanded: Set<ScanNode.ID> = []
    /// Set when the sidebar is clicked; the tree scrolls to it and clears it.
    var scrollTarget: ScanNode.ID?
    var sortOrder: TreeSortOrder = .sizeDescending

    // MARK: - Modes and status

    var deleteMode: DeleteMode {
        didSet { settings.deleteMode = deleteMode }
    }
    var isDeleting = false
    /// Non-nil while the confirmation sheet is up.
    var pendingPlan: DeletionPlan?
    /// Non-nil while the progress sheet is up.
    var deleteProgress: DeleteProgress?
    var toast: Toast?
    var lastScanFinished: Date?
    var scanStarted: Date?
    /// Total modules in the run, for "Scanning — 2 of 11 modules".
    var scanTotalModules = 0

    /// Shown at launch until dismissed. Not gated on the scan, so it is read before anything is
    /// selected rather than after.
    var showingDisclaimer = false
    var fullDiskAccessGranted = true
    var bannerDismissed = false

    /// Problem loading `config.json`. The file is never overwritten while this is set.
    var configError: String?

    // MARK: - Collaborators

    private(set) var config: UserConfig
    private let configStore = ConfigStore()
    private let settings = Settings()
    let stats = FreedStats()
    let shell = Shell()
    private let coordinator = ScanCoordinator()
    private let flattener = TreeFlattener()

    private var scanTask: Task<Void, Never>?
    private var deleteTask: Task<Void, Never>?

    init() {
        let loaded = configStore.load()
        config = loaded.config
        configError = loaded.error?.localizedDescription
        deleteMode = settings.deleteMode
    }

    // MARK: - Derived

    var isScanning: Bool { !scanning.isEmpty }
    var hasResults: Bool { !results.isEmpty }
    var showBanner: Bool { !fullDiskAccessGranted && !bannerDismissed }

    var totalBytes: Int64 {
        results.values.reduce(0) { $0 + $1.byteCount }
    }

    var configFileURL: URL { configStore.fileURL }

    /// Sidebar order, and the order the tree and the confirmation sheet group by.
    var moduleOrder: [String] { modules.map(\.id) }

    /// Visible rows: only expanded branches are walked, so this stays cheap.
    var rows: [FlatRow] {
        flattener.rows(
            modules: moduleOrder,
            results: results,
            expanded: expanded,
            sortedBy: sortOrder,
            minimumBytes: config.minItemSizeBytes
        )
    }

    /// Roots in sidebar order, filtered and sorted the same way the rows are — so selection
    /// totals count exactly what the user can see.
    var visibleRoots: [ScanNode] {
        moduleOrder.compactMap {
            flattener.prepared(results[$0], sortedBy: sortOrder, minimumBytes: config.minItemSizeBytes)
        }
    }

    var selectionTotals: (bytes: Int64, count: Int) {
        selection.totals(in: visibleRoots)
    }

    var scanProgressLabel: String {
        let done = scanTotalModules - scanning.count
        return "Scanning — \(max(0, done)) of \(scanTotalModules) modules"
    }

    /// The sidebar's footer line.
    var scanSummary: String {
        if isScanning {
            guard let started = scanStarted else { return "Scanning" }
            return "Scanning since \(Self.timeFormatter.string(from: started))"
        }
        guard let finished = lastScanFinished else { return "Not scanned" }
        return "Last scan: \(Self.timeFormatter.string(from: finished)) · "
            + "\(ByteFormatting.string(totalBytes)) measured"
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    // MARK: - Scanning

    /// Builds a context bound to the current config. Rebuilt per scan so config edits take
    /// effect without relaunching.
    private func makeContext(progressFor moduleID: String? = nil) -> ScanContext {
        ScanContext(
            shell: shell,
            config: config,
            progress: { [weak self] line in
                guard let self, let moduleID else { return }
                Task { @MainActor in self.statusLines[moduleID] = line }
            }
        )
    }

    func onAppear() {
        showingDisclaimer = !config.disclaimerAcknowledged
        fullDiskAccessGranted = FullDiskAccess.isGranted()
        if config.autoScanOnLaunch { rescanAll() }
    }

    func rescanAll() {
        scanTask?.cancel()
        scanTask = Task { await runScan(only: nil) }
    }

    func rescan(moduleID: String) {
        scanTask?.cancel()
        scanTask = Task { await runScan(only: [moduleID]) }
    }

    private func runScan(only ids: Set<String>?) async {
        fullDiskAccessGranted = FullDiskAccess.isGranted()

        var active = await ModuleRegistry.activeModules(ctx: makeContext())
        if let ids { active = active.filter { ids.contains($0.descriptor.id) } }

        // A partial rescan keeps the sidebar as it is; a full one rebuilds it, so a module that
        // has just been installed or uninstalled appears or disappears.
        if ids == nil {
            modules = active.map(\.descriptor)
            results.removeAll()
            errors.removeAll()
            emptyModules.removeAll()
        }

        scanning = Set(active.map(\.descriptor.id))
        scanTotalModules = active.count
        scanStarted = .now

        for await result in coordinator.scanAll(modules: active, ctx: makeContext()) {
            switch result.result {
            case .success(let node):
                results[result.moduleID] = node
                errors[result.moduleID] = nil
            case .failure(let failure) where failure.isEmpty:
                // Found nothing, which is not a problem worth a warning triangle.
                results[result.moduleID] = nil
                errors[result.moduleID] = nil
                if let descriptor = modules.first(where: { $0.id == result.moduleID }) {
                    emptyModules.append(
                        ModuleDescriptor(
                            id: descriptor.id,
                            title: descriptor.title,
                            systemImage: descriptor.systemImage,
                            requiresTool: failure.message,
                            defaultEnabled: descriptor.defaultEnabled
                        )
                    )
                }
                modules.removeAll { $0.id == result.moduleID }
            case .failure(let failure):
                errors[result.moduleID] = failure.message
                results[result.moduleID] = nil
            }
            scanning.remove(result.moduleID)
            statusLines[result.moduleID] = nil
            // The tree just changed shape, so container states have to be re-derived and states
            // for vanished nodes dropped.
            selection.resync(with: visibleRoots)
        }

        scanning.removeAll()
        selection.resync(with: visibleRoots)
        if !Task.isCancelled { lastScanFinished = .now }
    }

    func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        scanning.removeAll()
        statusLines.removeAll()
    }

    // MARK: - Tree actions

    func isExpanded(_ id: ScanNode.ID) -> Bool { expanded.contains(id) }

    func toggleExpanded(_ id: ScanNode.ID) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    func collapseAll() { expanded.removeAll() }

    func collapseOthers(keeping moduleID: String) {
        expanded = [moduleID]
        scrollTarget = moduleID
    }

    func jump(to moduleID: String) {
        expanded.insert(moduleID)
        scrollTarget = moduleID
    }

    func toggleSelection(_ node: ScanNode) {
        selection.toggle(node, in: visibleRoots)
    }

    func selectAllSafe(under node: ScanNode) {
        selection.selectAll(under: node, in: visibleRoots) { $0.risk == .safe }
    }

    func selectAll(under node: ScanNode) {
        selection.selectAll(under: node, in: visibleRoots) { _ in true }
    }

    func clearSelection() { selection.clear() }

    func setSortOrder(_ order: TreeSortOrder) { sortOrder = order }

    // MARK: - Shell-out actions

    func reveal(_ node: ScanNode) {
        guard let url = node.url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func resetStats() {
        stats.reset()
    }

    func openConfigFile() {
        NSWorkspace.shared.open(configStore.fileURL)
    }

    func openFullDiskAccessSettings() {
        guard let url = FullDiskAccess.settingsURL else { return }
        NSWorkspace.shared.open(url)
    }

    func hideModule(_ moduleID: String) {
        updateConfig { config in
            if !config.disabledModules.contains(moduleID) {
                config.disabledModules.append(moduleID)
            }
        }
        modules.removeAll { $0.id == moduleID }
        results[moduleID] = nil
        errors[moduleID] = nil
    }

    // MARK: - Deletion

    /// Builds the plan and opens the confirmation sheet. Nothing is touched yet.
    func requestDelete() {
        let plan = DeletionPlan(
            mode: deleteMode,
            selection: selection,
            roots: visibleRoots,
            titles: Dictionary(uniqueKeysWithValues: modules.map { ($0.id, $0.title) })
        )
        guard !plan.isEmpty else { return }
        pendingPlan = plan
    }

    func cancelDelete() {
        pendingPlan = nil
    }

    /// Runs the confirmed plan.
    func confirmDelete() {
        guard let plan = pendingPlan else { return }
        pendingPlan = nil
        isDeleting = true
        deleteProgress = DeleteProgress(plan: plan)

        deleteTask = Task { [plan] in
            let engine = DeletionEngine(
                pathGuard: PathGuard(roots: ModuleRegistry.allowedRoots(config: config)),
                modules: await ModuleRegistry.activeModules(ctx: makeContext())
            )
            let outcomes = await engine.run(plan, ctx: makeContext()) { outcome in
                Task { @MainActor in self.deleteProgress?.record(outcome) }
            }
            await finishDelete(plan: plan, outcomes: outcomes)
        }
    }

    /// Stops before the next item. An item already part-way through is allowed to finish, because
    /// a half-removed directory is worse than a slower stop.
    func stopDelete() {
        deleteTask?.cancel()
    }

    private func finishDelete(plan: DeletionPlan, outcomes: [DeleteOutcome]) async {
        let freed = outcomes.reduce(Int64(0)) { $0 + $1.freed }
        stats.add(freed)
        deleteProgress?.complete()
        isDeleting = false

        // Only what actually went away should stop being selected; a blocked item stays checked
        // so the user can retry it after shutting the simulator down.
        for outcome in outcomes where outcome.succeeded {
            selection.forget(outcome.nodeID)
        }

        toast = Toast(
            message: plan.mode.toastMessage(freed: freed),
            offersEmptyTrash: plan.mode.offersEmptyTrash && freed > 0
        )

        // Rescan only the modules that changed.
        //
        // Tool-driven deletions need a moment first. `xcrun simctl runtime delete` returns as
        // soon as the daemon accepts the request and finishes the work afterwards — measured at
        // well over a minute for several runtimes — so rescanning immediately reads the old
        // state and the deleted items reappear. The follow-up rescan closes the gap.
        let touched = Set(plan.groups.map(\.moduleID))
        let hadCommands = plan.hasCommands
        if !touched.isEmpty {
            scanTask = Task {
                if hadCommands {
                    try? await Task.sleep(for: .seconds(3))
                }
                await runScan(only: touched)
                if hadCommands {
                    try? await Task.sleep(for: .seconds(12))
                    guard !Task.isCancelled else { return }
                    await runScan(only: touched)
                }
            }
        }
    }

    func dismissProgress() {
        deleteProgress = nil
    }

    func dismissToast() {
        toast = nil
    }

    /// Trash mode does not reclaim space until the Trash is emptied, so this is offered rather
    /// than done — and only ever on an explicit click.
    func emptyTrash() {
        toast = nil
        Task {
            _ = try? await shell.run(
                executable: "/usr/bin/osascript",
                ["-e", "tell application \"Finder\" to empty trash"],
                timeout: .seconds(120)
            )
        }
    }

    func dismissDisclaimer(remember: Bool) {
        showingDisclaimer = false
        guard remember else { return }
        updateConfig { $0.disclaimerAcknowledged = true }
    }

    // MARK: - Custom locations

    /// Result of trying to add a folder, so the caller can show the reason it was refused.
    enum AddFolderResult {
        case added(CustomRoot)
        case refused(String)
    }

    /// Adds a folder the user picked, validates it, persists it to `config.json` and scans it.
    ///
    /// Validated at the point of entry so a folder that could never be deleted is refused with a
    /// reason, rather than accepted and then producing rows that silently do nothing.
    @discardableResult
    func addCustomLocation(_ url: URL) -> AddFolderResult {
        let path = DeletionPlan.abbreviate(url)

        if let error = ConfigStore.validateCustomRoot(path: path) {
            return .refused(error.localizedDescription)
        }
        if config.customRoots.contains(where: {
            $0.url.standardizedFileURL == url.standardizedFileURL
        }) {
            return .refused("\(url.lastPathComponent) is already in the list.")
        }

        let root = CustomRoot(
            id: Self.identifier(for: url, existing: config.customRoots),
            title: url.lastPathComponent,
            path: path,
            risk: .moderate,
            groupBy: .children
        )
        updateConfig { $0.customRoots.append(root) }

        // A module that was hidden because the list was empty has to come back before its
        // results have anywhere to go.
        rescanAll()
        return .added(root)
    }

    func removeCustomLocation(id: CustomRoot.ID) {
        updateConfig { config in
            config.customRoots.removeAll { $0.id == id }
        }
        if config.customRoots.isEmpty {
            modules.removeAll { $0.id == "custom" }
            results["custom"] = nil
        }
        rescan(moduleID: "custom")
    }

    func updateCustomLocation(id: CustomRoot.ID, _ mutate: (inout CustomRoot) -> Void) {
        updateConfig { config in
            guard let index = config.customRoots.firstIndex(where: { $0.id == id }) else { return }
            mutate(&config.customRoots[index])
        }
        rescan(moduleID: "custom")
    }

    /// Stable, readable and unique — node IDs derive from it, so it must survive a rescan.
    static func identifier(for url: URL, existing: [CustomRoot]) -> String {
        let base = url.lastPathComponent
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
        let stem = base.isEmpty ? "folder" : base
        var candidate = stem
        var suffix = 2
        while existing.contains(where: { $0.id == candidate }) {
            candidate = "\(stem)-\(suffix)"
            suffix += 1
        }
        return candidate
    }

    // MARK: - Config

    /// Writes through to `config.json`, the source of truth for these values.
    func updateConfig(_ mutate: (inout UserConfig) -> Void) {
        var copy = config
        mutate(&copy)
        config = copy
        do {
            try configStore.save(copy)
            configError = nil
        } catch {
            configError = error.localizedDescription
        }
    }
}
