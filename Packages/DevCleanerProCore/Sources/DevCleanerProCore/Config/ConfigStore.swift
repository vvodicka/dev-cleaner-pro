import Foundation

public enum ConfigError: Error, LocalizedError, Equatable {
    case unreadable(path: String, reason: String)
    case malformed(path: String, reason: String)
    case unwritable(path: String, reason: String)
    case rootRejected(path: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let path, let reason):
            "Could not read \(path): \(reason). Using defaults."
        case .malformed(let path, let reason):
            "\(path) is not valid JSON (\(reason)). Using defaults — your file has been left "
            + "untouched so you can fix it."
        case .unwritable(let path, let reason):
            "Could not save \(path): \(reason)"
        case .rootRejected(let path, let reason):
            "\"\(path)\" cannot be added: \(reason)"
        }
    }
}

/// Loads and saves `config.json`.
///
/// A malformed file is never overwritten. Silently replacing it with defaults would destroy
/// hand-written custom locations because of one stray comma, so the app reports the problem in a
/// banner, runs on defaults, and leaves the file for the user to fix (FR-5.1, doc 02).
public struct ConfigStore: Sendable {
    public let directory: URL
    public var fileURL: URL { directory.appending(path: "config.json") }

    public init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "DevCleanerPro", directoryHint: .isDirectory)
    }

    public struct LoadResult: Sendable {
        public var config: UserConfig
        /// Non-nil means the config on disk could not be used. `config` is then the defaults.
        public var error: ConfigError?
    }

    /// Reads the file, writing defaults on first launch.
    public func load() -> LoadResult {
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else {
            // First launch: materialise the file so the user has something to edit.
            let defaults = UserConfig.defaults
            do {
                try save(defaults)
            } catch let error as ConfigError {
                return LoadResult(config: defaults, error: error)
            } catch {
                return LoadResult(
                    config: defaults,
                    error: .unwritable(path: fileURL.path, reason: error.localizedDescription)
                )
            }
            return LoadResult(config: defaults, error: nil)
        }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            return LoadResult(
                config: .defaults,
                error: .unreadable(path: fileURL.path, reason: error.localizedDescription)
            )
        }

        do {
            let decoder = JSONDecoder()
            return LoadResult(config: try decoder.decode(UserConfig.self, from: data), error: nil)
        } catch {
            return LoadResult(
                config: .defaults,
                error: .malformed(path: fileURL.path, reason: Self.describe(error))
            )
        }
    }

    public func save(_ config: UserConfig) throws {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(config).write(to: fileURL, options: .atomic)
        } catch let error as ConfigError {
            throw error
        } catch {
            throw ConfigError.unwritable(path: fileURL.path, reason: error.localizedDescription)
        }
    }

    /// Opens the file in the user's editor. Wired to "Open config file" in Settings.
    public var configFileForEditing: URL { fileURL }

    // MARK: - Custom root validation

    /// Checks a folder the user is trying to add.
    ///
    /// This is the friendly, explain-yourself gate at the point of entry. `PathGuard` is the hard
    /// gate at the point of deletion, and it runs regardless of what passes here.
    public static func validateCustomRoot(path: String) -> ConfigError? {
        let expanded = (path as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else {
            return .rootRejected(path: path, reason: "it is not an absolute path")
        }

        let url = PathGuard.canonicalize(URL(fileURLWithPath: expanded))
        let home = PathGuard.canonicalize(URL(fileURLWithPath: NSHomeDirectory()))

        if url == home {
            return .rootRejected(
                path: path,
                reason: "your whole home folder is too broad to scan as one item"
            )
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return .rootRejected(path: path, reason: "the folder does not exist")
        }
        guard isDirectory.boolValue else {
            return .rootRejected(path: path, reason: "it is a file, not a folder")
        }

        // Ask the real guard whether anything inside could ever be deleted. If a probe path
        // under this root is refused, adding the root would only ever produce dead rows.
        let probing = PathGuard(roots: [AllowedRoot(url, deletableItself: true)])
        do {
            try probing.validate(url, home: home)
        } catch {
            return .rootRejected(
                path: path,
                reason: "it is a protected location DevCleanerPro will never delete"
            )
        }
        return nil
    }

    private static func describe(_ error: any Error) -> String {
        guard let decoding = error as? DecodingError else { return error.localizedDescription }
        switch decoding {
        case .dataCorrupted(let ctx):
            return ctx.debugDescription
        case .keyNotFound(let key, _):
            return "missing key \"\(key.stringValue)\""
        case .typeMismatch(_, let ctx), .valueNotFound(_, let ctx):
            let path = ctx.codingPath.map(\.stringValue).joined(separator: ".")
            return path.isEmpty ? ctx.debugDescription : "at \"\(path)\": \(ctx.debugDescription)"
        @unknown default:
            return error.localizedDescription
        }
    }
}
