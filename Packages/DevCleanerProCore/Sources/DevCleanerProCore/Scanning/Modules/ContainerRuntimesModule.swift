import Foundation

/// M13 — container and VM runtimes other than Docker Desktop.
///
/// Separate from the Docker module because these are alternative daemons, not part of it, and
/// each keeps its data in a place the other tools know nothing about. They share Docker's
/// awkward property: the images and volumes live inside one large VM disk image, so freeing
/// space inside it does not shrink the file until the tool compacts it.
public struct ContainerRuntimesModule: ScanModule {
    public init() {}

    public var descriptor: ModuleDescriptor {
        ModuleDescriptor(
            id: "containers",
            title: "Container runtimes",
            systemImage: "cube.transparent"
        )
    }

    struct Runtime {
        let id: String
        let title: String
        /// Home-relative paths holding the VM disk and image store.
        let paths: [String]
        let note: String
        /// The tool's own prune command, preferred over deleting the VM data by hand.
        var pruneTool: (tool: String, args: [String])?
        var risk: Risk = .careful
    }

    static let runtimes: [Runtime] = [
        Runtime(
            id: "orbstack",
            title: "OrbStack",
            paths: [".orbstack", "Library/Group Containers/HUAQ24HBR6.dev.orbstack"],
            note: "VM disk holding images, containers and volumes",
            pruneTool: ("docker", ["system", "prune", "-af"])
        ),
        Runtime(
            id: "colima",
            title: "Colima",
            paths: [".colima"],
            note: "Lima VM disk · `colima delete` resets it completely",
            pruneTool: ("colima", ["prune"])
        ),
        Runtime(
            id: "podman",
            title: "Podman",
            paths: [".local/share/containers", ".config/containers"],
            note: "image store and machine disk",
            pruneTool: ("podman", ["system", "prune", "-af"])
        ),
        Runtime(
            id: "lima",
            title: "Lima",
            paths: [".lima"],
            note: "VM disks, one per instance"
        ),
        Runtime(
            id: "rancher",
            title: "Rancher Desktop",
            paths: ["Library/Application Support/rancher-desktop", ".rd"],
            note: "VM disk and image store"
        ),
        Runtime(
            id: "vagrant",
            title: "Vagrant boxes",
            paths: [".vagrant.d/boxes"],
            note: "downloaded base boxes · re-downloaded by `vagrant up`",
            risk: .moderate
        ),
        Runtime(
            id: "virtualbox",
            title: "VirtualBox VMs",
            paths: ["VirtualBox VMs"],
            note: "whole virtual machines, including their disks — not a cache"
        ),
        Runtime(
            id: "utm",
            title: "UTM VMs",
            paths: ["Library/Containers/com.utmapp.UTM/Data/Documents"],
            note: "whole virtual machines, including their disks — not a cache"
        )
    ]

    public var roots: [AllowedRoot] {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        return Self.runtimes.flatMap { runtime in
            runtime.paths.map { AllowedRoot(home.appending(path: $0)) }
        }
    }

    public func isAvailable(_ ctx: ScanContext) async -> Bool {
        Self.runtimes.contains { runtime in
            ctx.anyExists(runtime.paths.map { ctx.path($0) })
        }
    }

    public func scan(_ ctx: ScanContext) async throws -> ScanNode {
        ctx.progress("Measuring container runtimes")
        var children: [ScanNode] = []

        for runtime in Self.runtimes {
            let present = runtime.paths.map { ctx.path($0) }.filter(ctx.exists)
            guard !present.isEmpty else { continue }

            var bytes: Int64 = 0
            for url in present {
                bytes += (await ctx.sizer.size(of: url, budget: .seconds(60)))?.bytes ?? 0
            }
            // A VM disk is never legitimately a few kilobytes. An empty UTM or Podman directory
            // left behind by an uninstall would otherwise put a 12 KB row in the sidebar.
            guard bytes > 10 * 1_048_576 else { continue }

            // Prefer the tool's own prune where the tool is installed: removing a VM disk by
            // hand leaves the runtime's own bookkeeping pointing at nothing.
            var action: DeleteAction = present.count == 1
                ? .removePath(present[0])
                : .removePaths(present)
            var note = runtime.note

            if let prune = runtime.pruneTool, let path = await ctx.shell.path(of: prune.tool) {
                action = .command(
                    executable: path,
                    args: prune.args,
                    displayName: "\(prune.tool) \(prune.args.joined(separator: " "))"
                )
                note += " · pruned by \(prune.tool) itself"
            }

            children.append(ScanNode(
                id: nodeID(runtime.id),
                title: runtime.title,
                subtitle: note,
                url: present[0],
                size: bytes,
                risk: runtime.risk,
                action: action
            ))
        }

        guard !children.isEmpty else {
            throw ScanFailure.empty("No container runtimes other than Docker found")
        }

        return ScanNode(
            id: descriptor.id,
            title: descriptor.title,
            subtitle: "VM disks and image stores · like Docker, these shrink only when the tool "
                + "compacts them",
            size: children.reduce(Int64(0)) { $0 + $1.byteCount },
            risk: .careful,
            children: children
        )
    }
}
