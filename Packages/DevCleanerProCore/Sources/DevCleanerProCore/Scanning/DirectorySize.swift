import Foundation

/// Result of walking one directory.
public struct DirectorySize: Sendable, Hashable {
    /// Allocated size on disk, in bytes.
    public var bytes: Int64
    public var fileCount: Int
    /// Entries that could not be read — almost always a missing Full Disk Access grant, or a
    /// `com.apple.*` cache the system protects. Surfaced rather than silently swallowed, so a
    /// total that is too low explains itself.
    public var unreadableCount: Int

    public static let zero = DirectorySize(bytes: 0, fileCount: 0, unreadableCount: 0)

    public init(bytes: Int64 = 0, fileCount: Int = 0, unreadableCount: Int = 0) {
        self.bytes = bytes
        self.fileCount = fileCount
        self.unreadableCount = unreadableCount
    }

    public static func + (lhs: DirectorySize, rhs: DirectorySize) -> DirectorySize {
        DirectorySize(
            bytes: lhs.bytes + rhs.bytes,
            fileCount: lhs.fileCount + rhs.fileCount,
            unreadableCount: lhs.unreadableCount + rhs.unreadableCount
        )
    }

    public static func += (lhs: inout DirectorySize, rhs: DirectorySize) {
        lhs = lhs + rhs
    }

    /// "3 unreadable", or nil when everything was measurable — ready to append to a subtitle.
    public var unreadableFragment: String? {
        unreadableCount > 0 ? "\(unreadableCount) unreadable" : nil
    }
}
