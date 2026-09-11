import Foundation

/// M3 — Docker images, containers, volumes and build cache.
///
/// The one module where the sizes and the disk footprint genuinely disagree, and the module says
/// so rather than picking whichever number looks better. Everything Docker stores on macOS lives
/// inside one sparse disk image, `Docker.raw`. Its *allocated* size is the real cost on disk;
/// the per-image and per-volume figures are logical sizes inside that image. Pruning frees space
/// within the file, but the file itself only shrinks when Docker Desktop compacts it — so
/// "reclaimed 18 GB" does not immediately show up in Finder, and pretending otherwise would be
/// the most misleading thing this app could do.
public struct DockerModule: ScanModule {
    public init() {}

    public var descriptor: ModuleDescriptor {
        ModuleDescriptor(
            id: "docker",
            title: "Docker",
            systemImage: "shippingbox",
            requiresTool: "docker"
        )
    }

    /// Nothing here is deleted by path — every operation goes through the Docker CLI, which is
    /// the only thing that can keep the daemon's own bookkeeping consistent. So no roots.
    public var roots: [AllowedRoot] { [] }

    public func isAvailable(_ ctx: ScanContext) async -> Bool {
        // Only the binary is required to *show* the module. A binary with a dead daemon is an
        // error state, not a hidden module — the user installed Docker and wants to see it
        // (doc 02).
        await ctx.shell.has("docker")
    }

    public func scan(_ ctx: ScanContext) async throws -> ScanNode {
        ctx.progress("Asking the Docker daemon")

        // `docker info` is the cheapest reliable liveness probe; the CLI hangs for a while
        // against a dead daemon, so a short timeout keeps a stopped Docker from stalling the scan.
        let info = try? await ctx.shell.run(
            tool: "docker", ["info", "--format", "{{.ServerVersion}}"], timeout: .seconds(20)
        )
        guard let info, info.succeeded else {
            throw ScanFailure(
                message: "Docker is installed but not running — start Docker Desktop and rescan."
            )
        }
        let version = info.stdout.trimmingCharacters(in: .whitespacesAndNewlines)

        // Resolved once, here. Docker Desktop installs into /usr/local/bin rather than a
        // Homebrew prefix, and a bare "docker" in a command action is a relative path that
        // Process cannot launch — so the absolute path goes into the action, which also means the
        // confirmation sheet shows the command that will genuinely run.
        guard let dockerPath = await ctx.shell.path(of: "docker") else {
            throw ScanFailure(message: "docker is no longer on the PATH")
        }

        // Tagged and dangling are fetched separately on purpose. Plain `docker images` omits
        // dangling layers entirely, and `-a` adds intermediate layers whose sizes overlap with
        // their children — on this machine `-a` sums to 39.2 GiB against an actual 22.0 GiB.
        async let imagesTask = load(ctx, ["images", "--format", "{{json .}}"], as: DockerImage.self)
        async let danglingTask = load(
            ctx, ["images", "-f", "dangling=true", "--format", "{{json .}}"], as: DockerImage.self
        )
        async let containersTask = load(ctx, ["ps", "-a", "--format", "{{json .}}"],
                                        as: DockerContainer.self)
        async let usageTask = load(ctx, ["system", "df", "--format", "{{json .}}"],
                                   as: DockerDiskUsage.self)

        let images = try await imagesTask
        let dangling = try await danglingTask
        let containers = try await containersTask
        let usage = try await usageTask
        let volumes = try await loadVolumes(ctx)

        var groups: [ScanNode] = []
        if let node = imagesGroup(images, dangling: dangling, containers: containers,
                                  usage: usage, docker: dockerPath) {
            groups.append(node)
        }
        if let node = containersGroup(containers, docker: dockerPath) { groups.append(node) }
        if let node = volumesGroup(volumes, docker: dockerPath) { groups.append(node) }
        if let node = buildCacheGroup(usage, docker: dockerPath) { groups.append(node) }

        let raw = try await diskImageNode(ctx)
        if let raw { groups.append(raw) }

        // The module's own figure is the real footprint when it is known, because that is the
        // number that matches the disk. The children explain what is inside it.
        let footprint = raw?.size
        return ScanNode(
            id: descriptor.id,
            title: descriptor.title,
            subtitle: footprint == nil
                ? "Docker \(version)"
                : "Docker \(version) · one sparse disk image holds everything below",
            size: footprint ?? groups.reduce(Int64(0)) { $0 + $1.byteCount },
            risk: .moderate,
            children: groups
        )
    }

    // MARK: - Loading

    private func load<T: Decodable>(
        _ ctx: ScanContext,
        _ args: [String],
        as type: T.Type
    ) async throws -> [T] {
        let result = try await ctx.shell.run(tool: "docker", args, timeout: .seconds(60))
        guard result.succeeded else {
            throw ScanFailure(message: "docker \(args[0]) failed: \(result.failureMessage)")
        }
        return try DockerParsing.lines(type, from: result.stdout)
    }

    /// Volume sizes only come from `system df -v`; `volume ls` reports "N/A" for every one.
    private func loadVolumes(_ ctx: ScanContext) async throws -> [DockerVolume] {
        let result = try await ctx.shell.run(
            tool: "docker", ["system", "df", "-v", "--format", "{{json .Volumes}}"],
            timeout: .seconds(120)
        )
        guard result.succeeded else { return [] }
        let payload = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !payload.isEmpty, payload != "null" else { return [] }
        return (try? JSONDecoder().decode([DockerVolume].self, from: Data(payload.utf8))) ?? []
    }

    // MARK: - Groups

    private func imagesGroup(
        _ images: [DockerImage],
        dangling: [DockerImage],
        containers: [DockerContainer],
        usage: [DockerDiskUsage],
        docker: String
    ) -> ScanNode? {
        guard !images.isEmpty || !dangling.isEmpty else { return nil }

        // `docker images` reports a container count, but it is "N/A" often enough that the
        // container list is the more reliable source for "is this image actually in use".
        let imagesInUse = Set(containers.map(\.image))

        var children: [ScanNode] = images.map { image in
            let inUse = image.isInUse || imagesInUse.contains(image.displayName)
            return ScanNode(
                // Keyed by repo:tag as well as image ID. Two tags of the same image share one
                // ID — `mcr.microsoft.com/playwright` and a private mirror of it, on this
                // machine — and a duplicate node ID makes SwiftUI render the row twice, tie
                // both copies' selection together, and add another copy on each rescan.
                id: nodeID("image/\(image.id)/\(image.repository):\(image.tag)"),
                title: image.displayName,
                subtitle: [
                    image.createdSince.isEmpty ? nil : "created \(image.createdSince)",
                    inUse ? "in use by a container" : nil
                ].compactMap { $0 }.joined(separator: " · "),
                size: image.bytes,
                risk: .moderate,
                action: .command(
                    executable: docker,
                    args: ["image", "rm", image.id],
                    displayName: "Remove image \(image.displayName)"
                ),
                blockedReason: inUse
                    ? "A container is using this image — remove the container first"
                    : nil
            )
        }

        if !dangling.isEmpty {
            children.append(ScanNode(
                id: nodeID("images/dangling"),
                title: "Dangling layers",
                subtitle: "\(dangling.count) untagged image\(dangling.count == 1 ? "" : "s") "
                    + "left behind by rebuilds",
                size: dangling.reduce(Int64(0)) { $0 + ($1.bytes ?? 0) },
                risk: .safe,
                // One prune beats 53 removals, and it is what the daemon documents.
                action: .command(
                    executable: docker,
                    args: ["image", "prune", "-f"],
                    displayName: "Prune dangling images"
                ),
                children: dangling.map { image in
                    // Informational rows: the group's prune covers them all, and offering 53
                    // individual removals would just be 53 ways to do the same thing.
                    ScanNode(
                        id: nodeID("dangling/\(image.id)"),
                        title: String(image.id.prefix(12)),
                        subtitle: image.createdSince.isEmpty
                            ? nil : "created \(image.createdSince)",
                        size: image.bytes,
                        risk: .info,
                        action: .none
                    )
                },
                // Worth a row: these are why some images cannot be removed yet.
                isAdvisory: true
            ))
        }

        // The authoritative total comes from `docker system df`, which deduplicates shared
        // layers. Summing the per-image sizes would overstate it badly, because Docker reports
        // each image's *full* size including layers it shares with others.
        let reported = usage.first { $0.type == "Images" }
        let inUseCount = children.count { $0.isBlocked }

        var subtitleParts = ["\(reported?.totalCount ?? "\(images.count)") images"]
        if inUseCount > 0 { subtitleParts.append("\(inUseCount) in use") }
        if let reclaimable = reported?.reclaimableBytes {
            subtitleParts.append("\(ByteFormatting.string(reclaimable)) reclaimable")
        }
        subtitleParts.append("per-image sizes include shared layers, so they do not sum")

        return ScanNode(
            id: nodeID("images"),
            title: "Images",
            subtitle: subtitleParts.joined(separator: " · "),
            size: reported?.bytes ?? children.reduce(Int64(0)) { $0 + $1.byteCount },
            risk: .moderate,
            children: children
        )
    }

    private func containersGroup(
        _ containers: [DockerContainer],
        docker: String
    ) -> ScanNode? {
        let stopped = containers.filter { !$0.isRunning }
        let running = containers.filter(\.isRunning)
        guard !stopped.isEmpty || !running.isEmpty else { return nil }

        var children: [ScanNode] = stopped.map { container in
            ScanNode(
                id: nodeID("container/\(container.id)"),
                title: container.names,
                subtitle: "\(container.image) · \(container.status)",
                size: container.bytes,
                risk: .moderate,
                action: .command(
                    executable: docker,
                    args: ["rm", container.id],
                    displayName: "Remove container \(container.names)"
                )
            )
        }

        if !running.isEmpty {
            children.append(ScanNode(
                id: nodeID("containers/running"),
                title: "Running",
                subtitle: "\(running.count) container\(running.count == 1 ? "" : "s") "
                    + "· stop them in Docker to make them removable",
                size: running.reduce(Int64(0)) { $0 + ($1.bytes ?? 0) },
                risk: .info,
                action: .none,
                children: running.map { container in
                    ScanNode(
                        id: nodeID("container/\(container.id)"),
                        title: container.names,
                        subtitle: "\(container.image) · \(container.status)",
                        size: container.bytes,
                        risk: .info,
                        action: .none
                    )
                }
            ))
        }

        return ScanNode(
            id: nodeID("containers"),
            title: "Containers",
            subtitle: "\(stopped.count) stopped, \(running.count) running",
            size: containers.reduce(Int64(0)) { $0 + ($1.bytes ?? 0) },
            risk: .moderate,
            children: children
        )
    }

    private func volumesGroup(_ volumes: [DockerVolume], docker: String) -> ScanNode? {
        guard !volumes.isEmpty else { return nil }

        let children = volumes.map { volume -> ScanNode in
            let unused = volume.isUnused
            return ScanNode(
                id: nodeID("volume/\(volume.name)"),
                title: volume.isAnonymous
                    ? "anonymous · \(volume.name.prefix(12))…"
                    : volume.name,
                subtitle: unused
                    ? "not attached to any container"
                    : "in use by \(volume.linkCount ?? 1) container(s)",
                size: volume.bytes,
                // Careful without exception: a volume is where a database keeps its data, and
                // "unused" only means no container is attached *right now*.
                risk: .careful,
                action: .command(
                    executable: docker,
                    args: ["volume", "rm", volume.name],
                    displayName: "Remove volume \(volume.name)"
                ),
                blockedReason: unused
                    ? nil
                    : "A container is attached to this volume — remove the container first"
            )
        }

        let unusedCount = volumes.count(where: \.isUnused)
        return ScanNode(
            id: nodeID("volumes"),
            title: "Volumes",
            subtitle: "\(volumes.count) volume\(volumes.count == 1 ? "" : "s")"
                + " · \(unusedCount) unattached · database contents live here",
            size: volumes.reduce(Int64(0)) { $0 + ($1.bytes ?? 0) },
            risk: .careful,
            children: children
        )
    }

    private func buildCacheGroup(
        _ usage: [DockerDiskUsage],
        docker: String
    ) -> ScanNode? {
        guard let cache = usage.first(where: { $0.type == "Build Cache" }),
              let bytes = cache.bytes, bytes > 0
        else { return nil }

        return ScanNode(
            id: nodeID("buildCache"),
            title: "Build cache",
            subtitle: "\(cache.totalCount) layer\(cache.count == 1 ? "" : "s")"
                + " · rebuilt on the next docker build",
            size: bytes,
            risk: .safe,
            action: .command(
                executable: docker,
                args: ["builder", "prune", "-af"],
                displayName: "Prune the whole build cache"
            )
        )
    }

    /// `Docker.raw` — the real footprint, and an explanation of why it does not match the sum.
    private func diskImageNode(_ ctx: ScanContext) async throws -> ScanNode? {
        let vms = ctx.path("Library/Containers/com.docker.docker/Data/vms")
        guard ctx.exists(vms) else { return nil }

        var candidates: [URL] = []
        for vm in try ctx.sizer.directChildren(of: vms) {
            let raw = vm.appending(path: "data/Docker.raw")
            if ctx.exists(raw) { candidates.append(raw) }
        }
        guard !candidates.isEmpty else { return nil }

        var total: Int64 = 0
        for raw in candidates {
            total += try await ctx.sizer.size(of: raw).bytes
        }

        return ScanNode(
            id: nodeID("diskImage"),
            title: "Docker Desktop disk image",
            subtitle: "actual space used on disk · pruning frees room inside this file, but it "
                + "only shrinks when Docker Desktop compacts it (Settings → Resources)",
            url: candidates[0],
            size: total,
            risk: .info,
            action: .none,
            // The real footprint, and the explanation for why the children do not sum to it.
            isAdvisory: true
        )
    }
}
