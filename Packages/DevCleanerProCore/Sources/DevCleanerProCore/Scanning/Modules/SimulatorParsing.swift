import Foundation

/// Decoded `xcrun simctl runtime list -j`.
///
/// Keyed by an opaque UUID, not by `runtimeIdentifier` — two entries can share
/// `com.apple.CoreSimulator.SimRuntime.iOS-26-4` with different builds, and keying by the
/// identifier would silently drop one of them (observed on the development machine).
public struct SimRuntime: Sendable, Identifiable, Decodable {
    public let identifier: String
    public let build: String
    public let version: String
    public let runtimeIdentifier: String
    public let state: String
    public let deletable: Bool
    public let sizeBytes: Int64?
    public let lastUsedAt: String?
    public let kind: String?
    /// Where the image actually lives. For "Patchable" runtimes this points inside
    /// `/System/Library/AssetsV2/…/<hash>.asset`; for plain Cryptex ones into
    /// `/Library/Developer/CoreSimulator/Cryptex/…`. Used to tell which stored images are still
    /// referenced.
    public let path: String?
    public let parentMountPath: String?
    public let mountPath: String?

    public var id: String { identifier }
    public var isReady: Bool { state == "Ready" }

    /// "iOS", "watchOS", "tvOS" — parsed from the runtime identifier's tail.
    public var platform: String {
        guard let tail = runtimeIdentifier.split(separator: ".").last else { return "Unknown" }
        return tail.split(separator: "-").first.map(String.init) ?? "Unknown"
    }

    /// "26.4" — the marketing version, from the identifier rather than `version`, which carries
    /// a patch component the simulator UI never shows.
    public var shortVersion: String {
        guard let tail = runtimeIdentifier.split(separator: ".").last else { return version }
        let parts = tail.split(separator: "-").dropFirst()
        return parts.isEmpty ? version : parts.joined(separator: ".")
    }

    /// "iOS 26.4 (23E244)" — the build is what distinguishes two runtimes of the same version.
    public var displayName: String {
        "\(platform) \(shortVersion) (\(build))"
    }

    public var lastUsedDate: Date? {
        lastUsedAt.flatMap { ISO8601DateFormatter().date(from: $0) }
    }
}

/// One simulator device from `xcrun simctl list devices -j`.
public struct SimDevice: Sendable, Identifiable, Decodable {
    public let udid: String
    public let name: String
    public let state: String
    public let isAvailable: Bool?
    public let dataPath: String?
    public let dataPathSize: Int64?
    public let logPath: String?
    public let logPathSize: Int64?
    public let lastBootedAt: String?
    public let availabilityError: String?

    public var id: String { udid }
    public var isBooted: Bool { state == "Booted" }
    public var isUsable: Bool { isAvailable ?? true }

    /// Data plus logs — both go when the device is deleted.
    public var totalBytes: Int64 { (dataPathSize ?? 0) + (logPathSize ?? 0) }

    public var lastBootedDate: Date? {
        lastBootedAt.flatMap { ISO8601DateFormatter().date(from: $0) }
    }
}

/// Parsers for the two `simctl` JSON shapes, separated from the module so they can be exercised
/// against the captured samples in `docs/samples/`.
public enum SimulatorParsing {
    /// `runtime list -j` returns an object keyed by runtime UUID.
    public static func runtimes(fromRuntimeListJSON data: Data) throws -> [SimRuntime] {
        let decoded = try JSONDecoder().decode([String: SimRuntime].self, from: data)
        return decoded.values.sorted { ($0.sizeBytes ?? 0) > ($1.sizeBytes ?? 0) }
    }

    /// `list devices -j` returns `{"devices": {"<runtimeIdentifier>": [device, …]}}`.
    /// Runtime identifiers with no devices are dropped.
    public static func devices(
        fromDeviceListJSON data: Data
    ) throws -> [String: [SimDevice]] {
        struct Wrapper: Decodable { let devices: [String: [SimDevice]] }
        let wrapper = try JSONDecoder().decode(Wrapper.self, from: data)
        return wrapper.devices.filter { !$0.value.isEmpty }
    }

    /// The `<hash>.asset` directory a runtime's image lives in, if it lives in one at all.
    ///
    /// Only "Patchable Cryptex Disk Image" runtimes are stored in `AssetsV2`; the older plain
    /// "Cryptex Disk Image" kind lives under `/Library/Developer/CoreSimulator/Cryptex`. Getting
    /// this wrong in either direction would be serious — a false orphan would tell the user to
    /// delete a runtime they are using.
    public static func assetDirectory(of runtime: SimRuntime) -> String? {
        for candidate in [runtime.path, runtime.parentMountPath] {
            guard let candidate else { continue }
            if let range = candidate.range(of: #"/System/Library/AssetsV2/[^/]+/[0-9a-f]+\.asset"#,
                                           options: .regularExpression) {
                return String(candidate[range])
            }
        }
        return nil
    }

    /// The `SimRuntimeBundle-<UUID>` directory a runtime's image lives in, for the older kind.
    public static func cryptexBundleName(of runtime: SimRuntime) -> String? {
        for candidate in [runtime.path, runtime.parentMountPath] {
            guard let candidate else { continue }
            if let range = candidate.range(of: #"SimRuntimeBundle-[0-9A-Fa-f-]+(_\d+)?"#,
                                           options: .regularExpression) {
                return String(candidate[range])
            }
        }
        return nil
    }
}
