import Foundation

/// Identity and presentation of a scan module. Order in `ModuleRegistry` is the sidebar order,
/// which doc 03 sets by typical size impact.
public struct ModuleDescriptor: Identifiable, Sendable, Hashable {
    /// "xcode", "simulators", "docker", ... Also the prefix of every node ID the module emits.
    public let id: String
    public let title: String
    /// SF Symbol name.
    public let systemImage: String
    /// Executable the module needs. When absent from `PATH` the module is *hidden*, not errored
    /// (doc 02: "Tool missing → module hidden (not error)").
    public let requiresTool: String?
    public let defaultEnabled: Bool

    public init(
        id: String,
        title: String,
        systemImage: String,
        requiresTool: String? = nil,
        defaultEnabled: Bool = true
    ) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.requiresTool = requiresTool
        self.defaultEnabled = defaultEnabled
    }
}
