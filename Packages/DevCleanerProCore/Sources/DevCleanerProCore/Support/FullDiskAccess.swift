import Foundation

/// Detects whether the app has Full Disk Access.
///
/// FR-7.1 implies the whole scan depends on this, which overstates it: `~/Library/Caches`,
/// `~/Library/Developer`, `~/.gradle` and `~/.npm` — most of what this app measures — are
/// readable without it. What genuinely needs the grant is `MobileSync/Backup` (iOS backups,
/// M10) and a handful of `com.apple.*` caches. So the banner names what is actually
/// unmeasurable instead of warning unconditionally (`docs/00-decisions.md`).
public enum FullDiskAccess {
    /// `~/Library/Safari` is the conventional probe: TCC-protected, present on every Mac, and
    /// listing it reads nothing sensitive.
    public static func isGranted(home: URL = URL(fileURLWithPath: NSHomeDirectory())) -> Bool {
        let probe = home.appending(path: "Library/Safari", directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: probe.path) else {
            // No Safari data at all — nothing to conclude, so do not nag.
            return true
        }
        return (try? FileManager.default.contentsOfDirectory(atPath: probe.path)) != nil
    }

    /// What the user loses without the grant. Used to word the banner concretely.
    public static let affectedAreas = "iOS device backups and some system caches"

    /// Opens the right pane of System Settings.
    public static let settingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
    )
}
