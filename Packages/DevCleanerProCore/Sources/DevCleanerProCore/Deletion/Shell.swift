import Foundation

public struct ShellResult: Sendable {
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32

    public var succeeded: Bool { exitCode == 0 }

    /// stderr when it says something, otherwise stdout — whichever is likelier to explain a failure.
    public var failureMessage: String {
        let e = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !e.isEmpty { return e }
        let o = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return o.isEmpty ? "exited with code \(exitCode)" : o
    }
}

public enum ShellError: Error, LocalizedError {
    case toolNotFound(String)
    case timedOut(command: String, after: Duration)
    case launchFailed(command: String, underlying: String)

    public var errorDescription: String? {
        switch self {
        case .toolNotFound(let tool):
            "\(tool) is not installed, or not on the PATH of your login shell."
        case .timedOut(let command, let after):
            "\(command) did not finish within \(after.components.seconds)s and was stopped."
        case .launchFailed(let command, let underlying):
            "Could not start \(command): \(underlying)"
        }
    }
}

/// Runs external tools. Every invocation uses an argv array — never `sh -c` with an interpolated
/// string — so a directory or image name containing spaces, quotes or semicolons cannot become
/// shell syntax. `sudo` is never used.
public actor Shell {
    /// Tools the modules in doc 03 may need.
    public static let knownTools = [
        "docker", "xcrun", "xcodebuild", "brew", "npm", "yarn", "pnpm", "pip3", "uv",
        "go", "cargo", "gradle", "tmutil", "pgrep", "osascript", "simctl", "git",
        "colima", "podman"
    ]

    /// Searched when the login shell does not know a tool. Docker Desktop installs into
    /// `/usr/local/bin`, Homebrew on Apple Silicon into `/opt/homebrew/bin`.
    private static let fallbackDirectories = [
        "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
        NSHomeDirectory() + "/.docker/bin"
    ]

    private var resolved: [String: String] = [:]
    /// The in-flight resolution, so concurrent callers await the same work instead of racing.
    private var resolution: Task<[String: String], Never>?

    public init() {}

    // MARK: - Tool resolution

    /// Resolves every known tool in one login-shell invocation, so a tool installed by nvm,
    /// pyenv, rustup or Homebrew is found the same way the user's own terminal finds it.
    /// Cheap and idempotent; safe to call from `isAvailable`.
    public func resolveTools() async {
        // A flag set before the work begins is not enough once callers are concurrent: the
        // second caller sees "already resolving", skips the wait, and reads an empty table — so
        // every tool-based module decided its tool was missing and hid itself. Holding the task
        // instead means everyone awaits the same result.
        if let resolution {
            resolved = await resolution.value
            return
        }
        let task = Task<[String: String], Never> {
            await Self.discoverTools()
        }
        resolution = task
        resolved = await task.value
    }

    private static func discoverTools() async -> [String: String] {
        var found: [String: String] = [:]

        let script = "for t in \(knownTools.joined(separator: " ")); do "
            + "p=$(command -v \"$t\" 2>/dev/null) && printf '%s=%s\\n' \"$t\" \"$p\"; done"
        let probe = Shell()
        if let result = try? await probe.runUnresolved(
            "/bin/zsh", ["-lc", script], timeout: .seconds(20)
        ) {
            for line in result.stdout.split(separator: "\n") {
                guard let sep = line.firstIndex(of: "=") else { continue }
                let name = String(line[line.startIndex..<sep])
                let path = String(line[line.index(after: sep)...])
                    .trimmingCharacters(in: .whitespaces)
                if !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) {
                    found[name] = path
                }
            }
        }

        // Fill any gaps by probing the usual install locations directly.
        for tool in knownTools where found[tool] == nil {
            for dir in fallbackDirectories {
                let candidate = dir + "/" + tool
                if FileManager.default.isExecutableFile(atPath: candidate) {
                    found[tool] = candidate
                    break
                }
            }
        }
        return found
    }

    /// Absolute path of a tool, or nil when it is not installed. A nil answer means the owning
    /// module hides itself rather than showing an error (doc 02).
    public func path(of tool: String) async -> String? {
        await resolveTools()
        return resolved[tool]
    }

    public func has(_ tool: String) async -> Bool {
        await path(of: tool) != nil
    }

    // MARK: - Running

    /// Runs a known tool by name, resolving it first.
    public func run(
        tool: String,
        _ args: [String],
        timeout: Duration = .seconds(120)
    ) async throws -> ShellResult {
        guard let executable = await path(of: tool) else { throw ShellError.toolNotFound(tool) }
        return try await runUnresolved(executable, args, timeout: timeout)
    }

    /// Runs an executable path.
    ///
    /// A bare name is resolved rather than passed to `Process` as a relative path, which would
    /// simply fail to launch. This is a backstop: a module that builds a `.command` action should
    /// resolve the tool at scan time so the confirmation sheet shows the real path. But such a
    /// mistake would otherwise only surface at delete time, as a launch failure on an action the
    /// user had already confirmed — so it is caught here as well.
    public func run(
        executable: String,
        _ args: [String],
        timeout: Duration = .seconds(120)
    ) async throws -> ShellResult {
        let resolved: String
        if executable.hasPrefix("/") {
            resolved = executable
        } else if let path = await path(of: executable) {
            resolved = path
        } else {
            throw ShellError.toolNotFound(executable)
        }
        return try await runUnresolved(resolved, args, timeout: timeout)
    }

    private func runUnresolved(
        _ executable: String,
        _ args: [String],
        timeout: Duration
    ) async throws -> ShellResult {
        let display = ([executable] + args).joined(separator: " ")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = Self.fallbackDirectories.joined(separator: ":")
        // Keep tool output machine-parseable and free of colour escapes.
        environment["LC_ALL"] = "C"
        environment["TERM"] = "dumb"
        environment["NO_COLOR"] = "1"
        process.environment = environment

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        // Installed before `run()`, because a process that exits first would never call a handler
        // attached afterwards.
        let exited = Exited()
        process.terminationHandler = { _ in exited.signal() }

        do {
            try process.run()
        } catch {
            throw ShellError.launchFailed(command: display, underlying: error.localizedDescription)
        }

        // Both pipes are drained concurrently with waiting. Reading only after exit deadlocks as
        // soon as a tool writes more than one pipe buffer — `docker system df -v` easily does.
        let stdoutTask = Task.detached { try? outPipe.fileHandleForReading.readToEnd() }
        let stderrTask = Task.detached { try? errPipe.fileHandleForReading.readToEnd() }

        let timedOut = await exited.wait(timeout: timeout)
        if timedOut {
            process.terminate()
            // Give it a moment to die politely, then insist.
            try? await Task.sleep(for: .milliseconds(500))
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            _ = await stdoutTask.value
            _ = await stderrTask.value
            throw ShellError.timedOut(command: display, after: timeout)
        }

        let outData = await stdoutTask.value ?? Data()
        let errData = await stderrTask.value ?? Data()
        return ShellResult(
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self),
            exitCode: process.terminationStatus
        )
    }
}

/// Bridges `Process.terminationHandler` — a C-style callback that can fire on any thread, at any
/// time, possibly before we start waiting — to a single `await`.
///
/// The subtlety worth knowing: both the exit wait and the timeout must be *children of the same
/// task group*. An earlier version created the timer with an unstructured `Task`, so
/// `group.cancelAll()` could not reach it and every call blocked for its full timeout even though
/// the process had already exited in milliseconds. Hence `withTaskCancellationHandler`, which
/// releases the exit continuation when the timeout wins so the group can actually finish.
private final class Exited: @unchecked Sendable {
    private let lock = NSLock()
    private var hasExited = false
    private var continuation: CheckedContinuation<Void, Never>?

    /// Called from `terminationHandler`: the process is genuinely gone.
    func signal() {
        lock.lock()
        hasExited = true
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume()
    }

    /// Releases a waiter without claiming the process exited — used when the timeout wins.
    private func abandon() {
        lock.lock()
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume()
    }

    private func park(_ cont: CheckedContinuation<Void, Never>) {
        lock.lock()
        if hasExited {
            lock.unlock()
            cont.resume()
        } else {
            continuation = cont
            lock.unlock()
        }
    }

    /// Returns true if the timeout won the race.
    func wait(timeout: Duration) async -> Bool {
        await withTaskGroup(of: Bool.self, returning: Bool.self) { group in
            group.addTask {
                await withTaskCancellationHandler {
                    await withCheckedContinuation { cont in self.park(cont) }
                } onCancel: {
                    self.abandon()
                }
                return false
            }
            group.addTask {
                do {
                    try await Task.sleep(for: timeout)
                    return true
                } catch {
                    // Cancelled because the process exited first: not a timeout.
                    return false
                }
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }
}
