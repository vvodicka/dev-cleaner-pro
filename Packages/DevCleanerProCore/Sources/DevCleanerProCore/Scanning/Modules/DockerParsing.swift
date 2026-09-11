import Foundation

/// Decoding for Docker's line-delimited `--format '{{json .}}'` output.
public enum DockerParsing {
    /// Parses Docker's human-readable sizes: "2.49GB", "976.8MB", "466kB (virtual 584MB)", "N/A".
    ///
    /// Docker formats these with `units.HumanSize`, which is **SI** — 1 kB is 1000 bytes, not
    /// 1024. Treating them as binary would overstate every figure by 7% at GB scale, and the
    /// numbers would not reconcile with what `docker system df` prints.
    ///
    /// Container sizes carry a parenthesised virtual size; only the leading writable-layer
    /// figure is the container's own cost, so the parenthesis is ignored.
    public static func bytes(from text: String) -> Int64? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != "N/A", trimmed != "<none>" else { return nil }

        let leading = trimmed.split(separator: " ").first.map(String.init) ?? trimmed
        let digits = leading.prefix { $0.isNumber || $0 == "." || $0 == "-" }
        guard let value = Double(digits) else { return nil }

        let unit = leading.dropFirst(digits.count).trimmingCharacters(in: .whitespaces)
        let multipliers: [String: Double] = [
            "B": 1, "": 1,
            "kB": 1_000, "KB": 1_000,
            "MB": 1_000_000,
            "GB": 1_000_000_000,
            "TB": 1_000_000_000_000,
            // Binary spellings, in case a future Docker switches formatter.
            "KiB": 1_024, "MiB": 1_048_576,
            "GiB": 1_073_741_824, "TiB": 1_099_511_627_776
        ]
        guard let multiplier = multipliers[unit] else { return nil }
        return Int64(value * multiplier)
    }

    /// Decodes newline-delimited JSON, skipping blank lines. Docker emits one object per line
    /// rather than a JSON array.
    public static func lines<T: Decodable>(_ type: T.Type, from output: String) throws -> [T] {
        let decoder = JSONDecoder()
        return try output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { try decoder.decode(T.self, from: Data($0.utf8)) }
    }
}

public struct DockerImage: Sendable, Decodable {
    public let id: String
    public let repository: String
    public let tag: String
    public let size: String
    /// Number of containers using this image, as a string. "N/A" when Docker did not compute it.
    public let containers: String
    public let createdSince: String

    enum CodingKeys: String, CodingKey {
        case id = "ID"
        case repository = "Repository"
        case tag = "Tag"
        case size = "Size"
        case containers = "Containers"
        case createdSince = "CreatedSince"
    }

    public var bytes: Int64? { DockerParsing.bytes(from: size) }
    /// An untagged layer left behind by a rebuild.
    public var isDangling: Bool { repository == "<none>" || tag == "<none>" }
    public var displayName: String {
        isDangling ? String(id.prefix(12)) : "\(repository):\(tag)"
    }
    /// Nil when Docker reported "N/A" rather than zero — not knowing is different from none.
    public var containerCount: Int? { Int(containers) }
    public var isInUse: Bool { (containerCount ?? 0) > 0 }
}

public struct DockerContainer: Sendable, Decodable {
    public let id: String
    public let names: String
    public let image: String
    public let state: String
    public let status: String
    public let size: String

    enum CodingKeys: String, CodingKey {
        case id = "ID"
        case names = "Names"
        case image = "Image"
        case state = "State"
        case status = "Status"
        case size = "Size"
    }

    public var bytes: Int64? { DockerParsing.bytes(from: size) }
    public var isRunning: Bool { state == "running" || state == "restarting" }
}

public struct DockerVolume: Sendable, Decodable {
    public let name: String
    public let size: String
    /// Number of containers referencing the volume. "0" means nothing would break.
    public let links: String
    public let labels: String?

    enum CodingKeys: String, CodingKey {
        case name = "Name"
        case size = "Size"
        case links = "Links"
        case labels = "Labels"
    }

    public var bytes: Int64? { DockerParsing.bytes(from: size) }
    public var linkCount: Int? { Int(links) }
    public var isUnused: Bool { (linkCount ?? 1) == 0 }
    /// Anonymous volumes are created implicitly by `docker run` and are rarely wanted.
    public var isAnonymous: Bool {
        labels?.contains("com.docker.volume.anonymous") == true
    }
}

/// One row of `docker system df`, used for the build-cache total.
public struct DockerDiskUsage: Sendable, Decodable {
    public let type: String
    public let totalCount: String
    public let active: String
    public let size: String
    public let reclaimable: String

    enum CodingKeys: String, CodingKey {
        case type = "Type"
        case totalCount = "TotalCount"
        case active = "Active"
        case size = "Size"
        case reclaimable = "Reclaimable"
    }

    public var bytes: Int64? { DockerParsing.bytes(from: size) }
    /// "18.51GB (78%)" → 18_510_000_000
    public var reclaimableBytes: Int64? {
        DockerParsing.bytes(from: reclaimable.split(separator: " ").first.map(String.init) ?? "")
    }
    public var count: Int? { Int(totalCount) }
}
