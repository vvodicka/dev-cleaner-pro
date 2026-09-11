import Foundation

public enum PathGuardError: Error, LocalizedError, Equatable {
    case notAbsolute(String)
    case notAFileURL(String)
    case outsideAllowedRoots(String)
    case isRootItself(String)
    case denyListed(String, rule: String)
    case symlinkEscapesRoot(path: String, target: String)

    public var errorDescription: String? {
        switch self {
        case .notAbsolute(let p):
            "Refused: \"\(p)\" is not an absolute path."
        case .notAFileURL(let p):
            "Refused: \"\(p)\" is not a file path."
        case .outsideAllowedRoots(let p):
            "Refused: \"\(p)\" lies outside every folder DevCleanerPro is allowed to touch."
        case .isRootItself(let p):
            "Refused: \"\(p)\" is a scan root itself, and this root may only have its contents removed."
        case .denyListed(let p, let rule):
            "Refused: \"\(p)\" is protected (\(rule))."
        case .symlinkEscapesRoot(let path, let target):
            "Refused: \"\(path)\" is a symlink pointing to \"\(target)\", outside the allowed folders."
        }
    }
}

/// The hard safety boundary. Nothing is deleted that this type has not approved.
///
/// Two independent checks must both pass, so a module declaring a careless root still cannot
/// reach anything important:
///
/// 1. **Allowlist** — the path is inside a registered `AllowedRoot`, or equals a root that opted
///    into `deletableItself`.
/// 2. **Deny-list** — the path is not a protected location. This overrides the allowlist and
///    `deletableItself` unconditionally.
///
/// Both the literal path and its symlink-resolved target are validated, so a symlink sitting
/// inside a root cannot be used to reach outside one.
public struct PathGuard: Sendable {
    private let roots: [AllowedRoot]

    public init(roots: [AllowedRoot]) {
        self.roots = roots
    }

    public var allowedRoots: [AllowedRoot] { roots }

    // MARK: - Canonicalisation

    /// Expands `~`, resolves symlinks, and removes `.` / `..`.
    ///
    /// Symlinks are resolved *before* `..` is collapsed, because collapsing `a/link/..`
    /// lexically would give `a`, which is wrong whenever `link` points elsewhere.
    public static func canonicalize(_ url: URL) -> URL {
        let expanded = (url.path as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded).resolvingSymlinksInPath().standardizedFileURL
    }

    // MARK: - Deny-list

    /// Locations whose entire subtree is untouchable.
    private static let deniedSubtrees: [String] = [
        "/System", "/Library", "/bin", "/sbin", "/usr", "/etc", "/var", "/private",
        "/Applications", "/cores", "/opt", "/dev", "/Network"
    ]

    /// Home-relative subtrees holding user documents or secrets.
    private static let deniedHomeSubtrees: [String] = [
        "Documents", "Desktop", "Downloads", "Pictures", "Music", "Movies", "Public",
        "Library/Keychains", "Library/Mobile Documents", "Library/CloudStorage",
        ".ssh", ".gnupg", ".aws", ".kube", ".config/gh"
    ]

    /// Directories that may have their *contents* removed but must survive themselves.
    /// Doc 02 phrases these as denied "as a whole".
    private static let deniedExactHomePaths: [String] = [
        "", // the home directory itself
        "Library",
        "Library/Application Support",
        "Library/Caches",
        "Library/Containers",
        "Library/Developer",
        "Library/Logs",
        "Library/Preferences",
        "Library/Saved Application State"
    ]

    private func denyReason(for url: URL, home: URL) -> String? {
        let path = url.path

        if path == "/" { return "the filesystem root" }

        // Any path with a Keychains component, wherever it sits.
        if url.pathComponents.contains("Keychains") { return "a keychain location" }

        for subtree in Self.deniedSubtrees where path == subtree || path.hasPrefix(subtree + "/") {
            return "inside \(subtree)"
        }

        // `/Users` itself, and any other user's home. The current user's home is handled by the
        // home rules below, which are narrower.
        if path == "/Users" { return "the users directory" }
        if path.hasPrefix("/Users/"), !isInside(url, of: home), url != home {
            return "another user's home folder"
        }

        // `/Volumes` and each volume's root. Deeper paths on an external disk stay usable,
        // because the design shows a custom location on `/Volumes/Work`.
        if path == "/Volumes" { return "the volumes directory" }
        if path.hasPrefix("/Volumes/"), url.pathComponents.count == 3 {
            return "the root of a mounted volume"
        }

        guard let relative = relativeComponents(of: url, under: home) else { return nil }
        let relativePath = relative.joined(separator: "/")

        if Self.deniedExactHomePaths.contains(relativePath) {
            return relativePath.isEmpty ? "your home folder" : "the ~/\(relativePath) folder itself"
        }
        for subtree in Self.deniedHomeSubtrees
        where relativePath == subtree || relativePath.hasPrefix(subtree + "/") {
            return "inside ~/\(subtree)"
        }
        return nil
    }

    // MARK: - Validation

    /// Approves a single path for deletion, or throws explaining why not.
    public func validate(_ url: URL, home: URL = URL(fileURLWithPath: NSHomeDirectory())) throws {
        guard url.isFileURL else { throw PathGuardError.notAFileURL(url.absoluteString) }

        let literal = URL(fileURLWithPath: (url.path as NSString).expandingTildeInPath)
            .standardizedFileURL
        guard literal.path.hasPrefix("/") else {
            throw PathGuardError.notAbsolute(url.path)
        }

        let canonicalHome = Self.canonicalize(home)
        let resolved = Self.canonicalize(url)

        // Validate the literal path and its symlink target independently. A symlink inside a
        // root that points outside one is refused rather than followed.
        if resolved != literal, !isAllowed(literal, home: canonicalHome) {
            throw PathGuardError.symlinkEscapesRoot(path: literal.path, target: resolved.path)
        }

        if let reason = denyReason(for: resolved, home: canonicalHome) {
            throw PathGuardError.denyListed(resolved.path, rule: reason)
        }
        if resolved != literal, let reason = denyReason(for: literal, home: canonicalHome) {
            throw PathGuardError.denyListed(literal.path, rule: reason)
        }

        guard let root = enclosingRoot(of: resolved) else {
            throw PathGuardError.outsideAllowedRoots(resolved.path)
        }
        if resolved == root.url, !root.deletableItself {
            throw PathGuardError.isRootItself(resolved.path)
        }
    }

    /// Convenience for a whole action. Command actions have no paths and always pass.
    public func validate(
        _ action: DeleteAction,
        home: URL = URL(fileURLWithPath: NSHomeDirectory())
    ) throws {
        for path in action.paths { try validate(path, home: home) }
    }

    /// Non-throwing form, for enabling UI without surfacing an error.
    public func allows(_ url: URL, home: URL = URL(fileURLWithPath: NSHomeDirectory())) -> Bool {
        (try? validate(url, home: home)) != nil
    }

    // MARK: - Helpers

    private func isAllowed(_ url: URL, home: URL) -> Bool {
        guard denyReason(for: url, home: home) == nil else { return false }
        guard let root = enclosingRoot(of: url) else { return false }
        return url != root.url || root.deletableItself
    }

    /// The most specific registered root containing `url`, or containing it as an equal.
    private func enclosingRoot(of url: URL) -> AllowedRoot? {
        roots
            .filter { url == $0.url || isInside(url, of: $0.url) }
            .max { $0.url.path.count < $1.url.path.count }
    }

    /// Strict containment by path component, so `/a/bc` is not treated as inside `/a/b`.
    private func isInside(_ url: URL, of parent: URL) -> Bool {
        let child = url.pathComponents
        let root = parent.pathComponents
        guard child.count > root.count else { return false }
        return Array(child.prefix(root.count)) == root
    }

    private func relativeComponents(of url: URL, under home: URL) -> [String]? {
        let child = url.pathComponents
        let base = home.pathComponents
        guard child.count >= base.count, Array(child.prefix(base.count)) == base else { return nil }
        return Array(child.dropFirst(base.count))
    }
}
