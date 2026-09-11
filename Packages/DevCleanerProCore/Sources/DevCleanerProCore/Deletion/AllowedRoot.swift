import Foundation

/// A directory a module is permitted to delete inside.
///
/// `docs/02-architecture.md` originally said a path must be "strictly inside an allowed root and
/// is not the root itself", but doc 03 has around ten nodes whose deletable path *is* the module
/// root — `~/Library/Caches/com.apple.dt.Xcode`, `~/Library/Caches/pip`,
/// `~/Library/Logs/CoreSimulator`. `deletableItself` is how a module opts one of its own roots
/// into being removable whole, instead of widening the allowlist a level (see
/// `docs/00-decisions.md` #1). The deny-list overrides it in every case.
public struct AllowedRoot: Sendable, Hashable {
    /// Canonicalised at init, so callers may pass `~`-style or symlinked paths.
    public let url: URL
    /// Whether this exact directory may be deleted, not only its contents.
    public let deletableItself: Bool

    public init(_ url: URL, deletableItself: Bool = false) {
        self.url = PathGuard.canonicalize(url)
        self.deletableItself = deletableItself
    }

    /// A root scanned for its size but never deletable — e.g.
    /// `/Library/Developer/CoreSimulator`, which doc 03 marks "read only for sizing".
    /// Size-only roots are simply never registered with `PathGuard`; this factory exists to make
    /// that intent explicit at the module's call site.
    public static func sizeOnly(_ url: URL) -> URL { PathGuard.canonicalize(url) }
}
