import Foundation

/// Everything a module needs to do its work, and nothing more.
///
/// Passed by value into every `scan`, so a module has no way to reach global state and is
/// trivially exercisable against a temporary directory by pointing `home` elsewhere.
public struct ScanContext: Sendable {
    /// The user's home directory. Modules build every path from this rather than calling
    /// `NSHomeDirectory()` themselves.
    public let home: URL
    public let sizer: DirectorySizer
    public let shell: Shell
    public let config: UserConfig
    /// Status line for this module — "Measuring DerivedData…". Called from a background task,
    /// so implementations hop to the main actor themselves.
    public let progress: @Sendable (String) -> Void

    public init(
        home: URL = URL(fileURLWithPath: NSHomeDirectory()),
        sizer: DirectorySizer = DirectorySizer(),
        shell: Shell,
        config: UserConfig,
        progress: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.home = home
        self.sizer = sizer
        self.shell = shell
        self.config = config
        self.progress = progress
    }

    /// Home-relative path helper: `ctx.path("Library/Developer/Xcode")`.
    public func path(_ relative: String) -> URL {
        home.appending(path: relative, directoryHint: .isDirectory)
    }

    public func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// True when at least one of the paths is present — the usual "should this module show at
    /// all?" question for path-based modules.
    public func anyExists(_ urls: [URL]) -> Bool {
        urls.contains(where: exists)
    }
}
