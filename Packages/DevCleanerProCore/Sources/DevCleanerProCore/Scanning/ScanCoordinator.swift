import Foundation

/// Runs modules concurrently and streams each one's result the moment it lands.
///
/// Streaming rather than gathering matters to how the app feels: `~/Library/Caches` finishes in a
/// second while the simulator folder can take twenty, and FR-1.2 requires each size to appear as
/// soon as it is known instead of the whole window waiting for the slowest module.
public struct ScanCoordinator: Sendable {
    /// How many modules measure at once.
    ///
    /// Starting all fourteen together is what made the window sit empty: they are all I/O bound
    /// on the same disk, so they finish together and late rather than one after another and
    /// early. A small number, fed cheapest-first from `ModuleRegistry`, means the quick modules
    /// are on screen within a second while the expensive ones queue behind them.
    ///
    /// Three rather than one core per module: these wait on the disk far more than they compute.
    public static let concurrentModules = 3

    /// Doc 03's common rule 1 sets this at 60 s. That does not survive contact with real
    /// directories: `~/.cocoapods/repos` on the development machine holds 1.82 million files and
    /// takes ~45 s to measure, with `du` itself needing 42 s — so no implementation reaches 60 s
    /// reliably for a tree like that, and a module that overran lost *all* of its results.
    ///
    /// The limit is therefore a backstop against a genuinely stuck module rather than a
    /// performance target, and modules that can be slow give their individual entries their own
    /// budget so they degrade to "size unknown" instead of returning nothing.
    public static let moduleTimeout: Duration = .seconds(180)

    public init() {}

    /// Cancelling the task that consumes the stream, or terminating the stream, cancels every
    /// module still running.
    public func scanAll(
        modules: [any ScanModule],
        ctx: ScanContext
    ) -> AsyncStream<ModuleResult> {
        AsyncStream { continuation in
            let work = Task {
                await withTaskGroup(of: ModuleResult.self) { group in
                    var pending = modules.makeIterator()
                    var running = 0

                    while running < Self.concurrentModules, let next = pending.next() {
                        group.addTask { await Self.scanOne(next, ctx) }
                        running += 1
                    }
                    while let result = await group.next() {
                        continuation.yield(result)
                        if let next = pending.next() {
                            group.addTask { await Self.scanOne(next, ctx) }
                        }
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in work.cancel() }
        }
    }

    /// Scans one module. Never throws: a module that fails or times out becomes a `.failure`
    /// result so the other ten keep going (doc 02: "Module-level errors don't fail the scan").
    static func scanOne(_ module: any ScanModule, _ ctx: ScanContext) async -> ModuleResult {
        let id = module.descriptor.id
        let clock = ContinuousClock()
        let start = clock.now

        let outcome: Result<ScanNode, ScanFailure> = await withTaskGroup(
            of: Result<ScanNode, ScanFailure>?.self,
            returning: Result<ScanNode, ScanFailure>.self
        ) { group in
            group.addTask {
                do {
                    return .success(try await module.scan(ctx))
                } catch {
                    return .failure(ScanFailure(error))
                }
            }
            group.addTask {
                try? await Task.sleep(for: moduleTimeout)
                // A cancelled sleep returns here too, so only report a timeout if the task is
                // still live — otherwise a cancelled scan would be mislabelled.
                guard !Task.isCancelled else { return nil }
                return .failure(ScanFailure(
                    message: "\(module.descriptor.title) took longer than "
                        + "\(moduleTimeout.components.seconds)s and was stopped.",
                    isTimeout: true
                ))
            }

            // First non-nil answer wins; the loser is cancelled.
            while let next = await group.next() {
                if let next {
                    group.cancelAll()
                    return next
                }
            }
            return .failure(ScanFailure(message: "Cancelled"))
        }

        return ModuleResult(moduleID: id, result: outcome, duration: start.duration(to: clock.now))
    }
}
