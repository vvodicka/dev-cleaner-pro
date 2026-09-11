import Foundation

/// One scannable area: Xcode, Docker, package caches, and so on.
///
/// Adding a module means one file in `Scanning/Modules/`, one line in `ModuleRegistry`, and no UI
/// changes at all — that is the project's definition of done (doc 04).
public protocol ScanModule: Sendable {
    var descriptor: ModuleDescriptor { get }

    /// Every directory this module may delete inside. Registered with `PathGuard` at startup, so
    /// a path the module forgot to declare here cannot be deleted even if a node points at it.
    ///
    /// Paths measured but never deleted — `/Library/Developer/CoreSimulator`, say — belong
    /// outside this list.
    var roots: [AllowedRoot] { get }

    /// Whether to show the module at all. A missing tool or absent root means hidden, not
    /// errored: an empty Docker row on a machine without Docker is noise (doc 02).
    func isAvailable(_ ctx: ScanContext) async -> Bool

    /// Builds the module's subtree. The returned node is the depth-0 row.
    func scan(_ ctx: ScanContext) async throws -> ScanNode

    /// Last word before deleting one node — a booted simulator, a running container, an open IDE.
    /// Returns the reason to block, or nil to proceed.
    ///
    /// Re-checked immediately before deletion rather than trusted from scan time, because the
    /// user may have booted a simulator in between.
    func preDeleteCheck(_ node: ScanNode, _ ctx: ScanContext) async -> String?
}

extension ScanModule {
    /// Most modules are available whenever their tool exists and at least one root is present.
    public func isAvailable(_ ctx: ScanContext) async -> Bool {
        if let tool = descriptor.requiresTool, await !ctx.shell.has(tool) {
            return false
        }
        return roots.isEmpty || ctx.anyExists(roots.map(\.url))
    }

    /// Most modules have nothing that can be in use.
    public func preDeleteCheck(_ node: ScanNode, _ ctx: ScanContext) async -> String? { nil }

    /// Namespaced node ID, so IDs stay unique and stable across modules.
    /// `node(":derived-data", ...)` in the Xcode module becomes `"xcode/derived-data"`.
    public func nodeID(_ suffix: String) -> String {
        "\(descriptor.id)/\(suffix)"
    }
}

/// Why a module could not be scanned.
///
/// Carries a message rather than the original error, because the only thing the UI does with it
/// is show it beside the ⚠︎ — and a concrete `Sendable` type keeps `ModuleResult` sendable
/// without existential gymnastics.
public struct ScanFailure: Error, Sendable, Equatable {
    public let message: String
    /// A timed-out module shows partial results where it can, rather than nothing.
    public let isTimeout: Bool
    /// The module worked fine and found nothing. Not an error — the module hides itself, because
    /// a permanent warning triangle over "there are no iOS backups on this Mac" is noise
    /// dressed up as a problem.
    public let isEmpty: Bool

    public init(message: String, isTimeout: Bool = false, isEmpty: Bool = false) {
        self.message = message
        self.isTimeout = isTimeout
        self.isEmpty = isEmpty
    }

    /// A module reporting that it has nothing to show.
    public static func empty(_ message: String) -> ScanFailure {
        ScanFailure(message: message, isEmpty: true)
    }

    public init(_ error: any Error) {
        if let failure = error as? ScanFailure {
            self = failure
        } else if error is CancellationError {
            self.init(message: "Cancelled")
        } else {
            self.init(message: error.localizedDescription)
        }
    }
}

/// Outcome of scanning one module, as streamed by the coordinator.
public struct ModuleResult: Sendable {
    public let moduleID: String
    public let result: Result<ScanNode, ScanFailure>
    public let duration: Duration

    public init(moduleID: String, result: Result<ScanNode, ScanFailure>, duration: Duration) {
        self.moduleID = moduleID
        self.result = result
        self.duration = duration
    }

    public var node: ScanNode? {
        try? result.get()
    }

    public var failure: ScanFailure? {
        guard case .failure(let f) = result else { return nil }
        return f
    }
}
