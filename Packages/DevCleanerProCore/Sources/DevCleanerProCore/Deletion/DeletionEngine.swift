import Foundation

/// Result of trying to delete one item.
public struct DeleteOutcome: Sendable, Identifiable {
    public let nodeID: ScanNode.ID
    public let moduleID: String
    public let title: String
    /// Abbreviated path or command, for the progress list.
    public let detail: String
    /// Bytes actually reclaimed. Measured before deletion, and zero when the item failed.
    public let freed: Int64
    public let error: String?

    public var id: ScanNode.ID { nodeID }
    public var succeeded: Bool { error == nil }
}

/// Carries out a `DeletionPlan`.
///
/// Never aborts the batch: one refused path or one running container must not strand the other
/// thirty items (FR-4.3). Every failure is collected and shown against its row.
public actor DeletionEngine {
    /// Doc 02: sequential within a module, at most three modules at once. Modules are serialised
    /// internally because two `rm`s in the same tree contend on the same directory, while
    /// separate modules touch unrelated parts of the disk.
    public static let moduleConcurrency = 3

    private let pathGuard: PathGuard
    /// moduleID → module, for `preDeleteCheck`.
    private let modules: [String: any ScanModule]

    public init(pathGuard: PathGuard, modules: [any ScanModule]) {
        self.pathGuard = pathGuard
        self.modules = Dictionary(
            modules.map { ($0.descriptor.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// - Parameter onProgress: called as each item finishes, on an arbitrary task.
    /// - Returns: one outcome per item, including the ones that failed.
    public func run(
        _ plan: DeletionPlan,
        ctx: ScanContext,
        onProgress: @escaping @Sendable (DeleteOutcome) -> Void
    ) async -> [DeleteOutcome] {
        var all: [DeleteOutcome] = []
        var pending = plan.groups.makeIterator()
        var inFlight = 0

        await withTaskGroup(of: [DeleteOutcome].self) { group in
            while inFlight < Self.moduleConcurrency, let next = pending.next() {
                group.addTask {
                    await self.runGroup(next, mode: plan.mode, ctx: ctx, onProgress: onProgress)
                }
                inFlight += 1
            }
            while let finished = await group.next() {
                all.append(contentsOf: finished)
                if let next = pending.next() {
                    group.addTask {
                        await self.runGroup(next, mode: plan.mode, ctx: ctx, onProgress: onProgress)
                    }
                }
            }
        }
        return all
    }

    private func runGroup(
        _ group: DeletionPlan.Group,
        mode: DeleteMode,
        ctx: ScanContext,
        onProgress: @escaping @Sendable (DeleteOutcome) -> Void
    ) async -> [DeleteOutcome] {
        var outcomes: [DeleteOutcome] = []
        for item in group.items {
            // Stop starting new work when cancelled, but never interrupt an item that is already
            // part-way through — a half-deleted directory is worse than a slower stop.
            if Task.isCancelled {
                outcomes.append(DeleteOutcome(
                    nodeID: item.node.id,
                    moduleID: group.moduleID,
                    title: item.node.title,
                    detail: item.operations.first ?? "",
                    freed: 0,
                    error: "Stopped before this item"
                ))
                continue
            }
            let outcome = await perform(item, moduleID: group.moduleID, mode: mode, ctx: ctx)
            outcomes.append(outcome)
            onProgress(outcome)
        }
        return outcomes
    }

    private func perform(
        _ item: DeletionPlan.Item,
        moduleID: String,
        mode: DeleteMode,
        ctx: ScanContext
    ) async -> DeleteOutcome {
        let node = item.node
        let detail = item.operations.first ?? node.title

        func outcome(freed: Int64, error: String?) -> DeleteOutcome {
            DeleteOutcome(
                nodeID: node.id,
                moduleID: moduleID,
                title: node.title,
                detail: detail,
                freed: freed,
                error: error
            )
        }

        // Re-checked here rather than trusted from scan time: the user may have booted a
        // simulator or started a container while the confirmation sheet was open.
        if let module = modules[moduleID],
           let reason = await module.preDeleteCheck(node, ctx) {
            return outcome(freed: 0, error: reason)
        }

        switch node.action {
        case .none:
            return outcome(freed: 0, error: "Nothing to delete")

        case .removePath(let url):
            do {
                try pathGuard.validate(url, home: ctx.home)
                try remove(url, mode: mode)
                return outcome(freed: node.byteCount, error: nil)
            } catch {
                return outcome(freed: 0, error: message(for: error))
            }

        case .removePaths(let urls):
            // All-or-nothing on validation: a group is one logical item, and removing half an
            // AVD would leave Android Studio with a broken entry.
            do {
                for url in urls { try pathGuard.validate(url, home: ctx.home) }
            } catch {
                return outcome(freed: 0, error: message(for: error))
            }
            var failures: [String] = []
            for url in urls where FileManager.default.fileExists(atPath: url.path) {
                do {
                    try remove(url, mode: mode)
                } catch {
                    failures.append("\(url.lastPathComponent): \(message(for: error))")
                }
            }
            return failures.isEmpty
                ? outcome(freed: node.byteCount, error: nil)
                : outcome(freed: 0, error: failures.joined(separator: "; "))

        case .command(let executable, let args, let displayName):
            do {
                let result = try await ctx.shell.run(
                    executable: executable, args, timeout: .seconds(300)
                )
                guard result.succeeded else {
                    // A tool reporting that the thing is not there has delivered the outcome the
                    // user asked for. Treating it as a failure was actively confusing: deleting a
                    // simulator runtime twice showed "not found — run runtime list" as an error,
                    // when in fact it had already gone.
                    if Self.meansAlreadyGone(result.failureMessage) {
                        return outcome(freed: node.byteCount, error: nil)
                    }
                    return outcome(freed: 0, error: result.failureMessage)
                }
                return outcome(freed: node.byteCount, error: nil)
            } catch {
                return outcome(freed: 0, error: "\(displayName): \(message(for: error))")
            }
        }
    }

    /// Command items bypass this entirely — running a tool is irreversible whatever the mode
    /// says, which is why the confirmation sheet marks them separately.
    private func remove(_ url: URL, mode: DeleteMode) throws {
        switch mode {
        case .trash:
            var resulting: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        case .permanent:
            try FileManager.default.removeItem(at: url)
        }
    }

    /// Recognises "it was not there" across the tools this app drives.
    static func meansAlreadyGone(_ message: String) -> Bool {
        let lowered = message.lowercased()
        let phrases = [
            "no such file or directory",
            "not found",
            "unable to find",
            "no matching",
            "does not exist",
            "no such container",
            "no such image",
            "no such volume",
            "invalid runtime"
        ]
        return phrases.contains { lowered.contains($0) }
    }

    private func message(for error: any Error) -> String {
        if let guardError = error as? PathGuardError {
            return guardError.errorDescription ?? "\(guardError)"
        }
        if let shellError = error as? ShellError {
            return shellError.errorDescription ?? "\(shellError)"
        }
        let ns = error as NSError
        // The bare Cocoa message for EPERM is unhelpful on its own.
        if ns.domain == NSCocoaErrorDomain, ns.code == NSFileWriteNoPermissionError {
            return "Operation not permitted — grant Full Disk Access to DevCleanerPro and retry."
        }
        return ns.localizedDescription
    }
}
