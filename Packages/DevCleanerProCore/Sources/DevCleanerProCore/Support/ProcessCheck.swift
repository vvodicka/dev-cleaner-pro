import Foundation

/// Answers "is this running right now?" so a cache in use is blocked rather than pulled out from
/// under a live process.
///
/// Uses `pgrep` rather than `NSWorkspace.runningApplications`, because the things worth guarding
/// against are not all GUI apps — `xcodebuild`, `qemu-system-aarch64` and JetBrains' JVM helpers
/// never appear in the workspace list.
public struct ProcessCheck: Sendable {
    private let shell: Shell

    public init(shell: Shell) {
        self.shell = shell
    }

    /// True if any process matches the pattern. `pgrep -f` matches the full command line.
    public func isRunning(pattern: String) async -> Bool {
        guard let pgrep = await shell.path(of: "pgrep") else { return false }
        // pgrep exits 1 when nothing matched, which is an answer rather than an error.
        guard let result = try? await shell.run(
            executable: pgrep, ["-f", pattern], timeout: .seconds(10)
        ) else { return false }
        return result.succeeded && !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Names of matching processes, for a message that says which one to quit.
    public func runningNames(pattern: String) async -> [String] {
        guard let pgrep = await shell.path(of: "pgrep") else { return [] }
        guard let result = try? await shell.run(
            executable: pgrep, ["-fl", pattern], timeout: .seconds(10)
        ), result.succeeded else { return [] }
        return result.stdout
            .split(separator: "\n")
            .compactMap { line in
                // "1234 /Applications/Xcode.app/Contents/MacOS/Xcode" → "Xcode"
                let parts = line.split(separator: " ", maxSplits: 1)
                guard parts.count == 2 else { return nil }
                return URL(fileURLWithPath: String(parts[1])).lastPathComponent
            }
    }
}
