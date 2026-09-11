import Foundation
import DevCleanerProCore

/// Runtime self-check for the two things that cannot be verified by looking at a scan: whether
/// `PathGuard` actually refuses what it claims to, and whether deletion does what the
/// confirmation sheet promised.
///
/// Lives in the diagnostic CLI rather than a test target so it can be run against the real
/// machine at any time — `swift run dcp-scan --self-check` — and so the safety model is
/// demonstrable rather than merely asserted.
///
/// It never runs `DeletionEngine`: carrying out a real deletion is left to manual testing. What
/// it does exercise is `PathGuard.validate`, which only inspects paths, and the pure selection
/// and plan logic over synthetic nodes whose paths do not exist.
///
/// The one place it touches the filesystem is the symlink fixture, which needs real links for
/// `PathGuard` to resolve. Those files it creates itself, under
/// `~/Library/Caches/dev.vodicka.DevCleanerPro.selfcheck`, and removes on the way out. It never
/// writes or deletes outside that folder.
struct SelfCheck {
    private var failures: [String] = []
    private var passes = 0

    private mutating func expect(_ condition: Bool, _ description: String) {
        if condition {
            passes += 1
            print("  ok    \(description)")
        } else {
            failures.append(description)
            print("  FAIL  \(description)")
        }
    }

    private mutating func expectRefused(
        _ description: String,
        _ body: () throws -> Void
    ) {
        do {
            try body()
            failures.append(description)
            print("  FAIL  \(description) — was allowed")
        } catch {
            passes += 1
            print("  ok    \(description)")
        }
    }

    private mutating func expectAllowed(
        _ description: String,
        _ body: () throws -> Void
    ) {
        do {
            try body()
            passes += 1
            print("  ok    \(description)")
        } catch {
            failures.append(description)
            print("  FAIL  \(description) — refused: \(error)")
        }
    }

    // MARK: - Entry point

    static func run() async -> Int32 {
        var check = SelfCheck()
        let fm = FileManager.default
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let scratch = home
            .appending(path: "Library/Caches/dev.vodicka.DevCleanerPro.selfcheck")
            .appending(path: UUID().uuidString)

        defer {
            try? fm.removeItem(at: scratch)
            // Remove the container too, but only while it is empty — a concurrent run's folder
            // must not be swept away.
            let container = scratch.deletingLastPathComponent()
            if let entries = try? fm.contentsOfDirectory(atPath: container.path), entries.isEmpty {
                try? fm.removeItem(at: container)
            }
        }

        print("PathGuard")
        check.checkPathGuard(home: home)

        print("")
        print("PathGuard — symlinks on the real filesystem")
        await check.checkSymlinks(scratch: scratch, home: home)

        print("")
        print("Directory sizing")
        await check.checkSizing(scratch: scratch)

        print("")
        print("Selection and planning (no deletion is performed)")
        check.checkPlanning(home: home)

        print("")
        print("Configuration")
        check.checkConfig(scratch: scratch, home: home)

        print("")
        print("Module registry")
        check.checkRegistry(home: home)

        print("")
        print("Git repository waste")
        await check.checkGitModule(scratch: scratch)

        print("")
        if check.failures.isEmpty {
            print("\(check.passes) checks passed")
            return 0
        }
        print("\(check.passes) passed, \(check.failures.count) FAILED:")
        for failure in check.failures { print("  - \(failure)") }
        return 1
    }

    // MARK: - PathGuard

    private mutating func checkPathGuard(home: URL) {
        func h(_ relative: String) -> URL {
            home.appending(path: relative, directoryHint: .isDirectory)
        }

        let caches = h("Library/Caches")
        let guardCaches = PathGuard(roots: [AllowedRoot(caches)])

        expectAllowed("a path inside a root is allowed") {
            try guardCaches.validate(caches.appending(path: "com.example.app"), home: home)
        }
        expectRefused("a path outside every root is refused") {
            try guardCaches.validate(h("Library/Logs/x"), home: home)
        }
        expectRefused("with no roots, nothing is allowed") {
            try PathGuard(roots: []).validate(caches.appending(path: "x"), home: home)
        }

        // deletableItself
        let pip = h("Library/Caches/pip")
        expectRefused("a root that did not opt in cannot be deleted itself") {
            try PathGuard(roots: [AllowedRoot(pip)]).validate(pip, home: home)
        }
        expectAllowed("a root that opted in can be deleted itself") {
            try PathGuard(roots: [AllowedRoot(pip, deletableItself: true)]).validate(pip, home: home)
        }
        expectRefused("deletableItself never overrides the deny-list") {
            try PathGuard(roots: [AllowedRoot(h("Library"), deletableItself: true)])
                .validate(h("Library"), home: home)
        }

        // Deny-list, against the widest possible allowlist.
        let wideOpen = PathGuard(roots: [AllowedRoot(home, deletableItself: true)])
        let protectedRelatives = [
            "", "Library", "Library/Caches", "Library/Application Support",
            "Library/Developer", "Library/Logs", "Library/Containers",
            "Library/Saved Application State", "Library/Preferences",
            "Documents/tax.pdf", "Desktop/notes.txt", "Downloads/x.dmg",
            "Pictures/Photos.photoslibrary", "Music/x", "Movies/x",
            "Library/Keychains/login.keychain-db", "Library/Mobile Documents/x",
            "Library/CloudStorage/x", ".ssh/id_ed25519", ".gnupg/secring.gpg",
            ".aws/credentials", ".kube/config"
        ]
        for relative in protectedRelatives {
            let target = relative.isEmpty ? home : home.appending(path: relative)
            expectRefused("protected: ~/\(relative.isEmpty ? "" : relative)") {
                try wideOpen.validate(target, home: home)
            }
        }

        // Same, with "/" itself opted in — the most reckless declaration possible.
        let reckless = PathGuard(roots: [AllowedRoot(URL(fileURLWithPath: "/"), deletableItself: true)])
        for path in ["/", "/System", "/System/Library/AssetsV2/x.asset", "/Library",
                     "/usr/bin/swift", "/bin/sh", "/etc/hosts", "/var/log/x",
                     "/private/var/folders/x", "/Applications/Xcode.app",
                     "/opt/homebrew/bin/brew", "/Users", "/Users/someoneelse/Library",
                     "/Volumes", "/Volumes/BackupDisk"] {
            expectRefused("protected: \(path)") {
                try reckless.validate(URL(fileURLWithPath: path), home: home)
            }
        }

        expectRefused("a Keychains component is refused wherever it appears") {
            try guardCaches.validate(caches.appending(path: "Keychains/stray.db"), home: home)
        }
        expectAllowed("children of an exact-denied directory stay deletable") {
            try guardCaches.validate(caches.appending(path: "com.apple.dt.Xcode"), home: home)
        }

        // Traversal and prefix traps.
        expectRefused("a sibling sharing a name prefix is not inside the root") {
            try PathGuard(roots: [AllowedRoot(pip)])
                .validate(h("Library/Caches/pip-secrets/token"), home: home)
        }
        expectRefused("dot-dot out of the root is refused") {
            try guardCaches.validate(caches.appending(path: "../../.ssh/id_ed25519"), home: home)
        }
        expectAllowed("dot-dot that stays inside the root is fine") {
            try guardCaches.validate(caches.appending(path: "a/../b"), home: home)
        }
        expectRefused("a relative path is refused") {
            try guardCaches.validate(URL(fileURLWithPath: "Library/Caches/x", relativeTo: nil),
                                     home: home)
        }
        if let web = URL(string: "https://example.com/etc/passwd") {
            expectRefused("a non-file URL is refused") {
                try guardCaches.validate(web, home: home)
            }
        }

        // External volumes: the volume root is protected, deeper paths are usable.
        let volumeRoot = URL(fileURLWithPath: "/Volumes/Work/ci-artifacts")
        let volumeGuard = PathGuard(roots: [AllowedRoot(volumeRoot, deletableItself: true)])
        expectAllowed("a deep path on an external volume is allowed when declared") {
            try volumeGuard.validate(volumeRoot.appending(path: "build-1"), home: home)
        }

        // Multi-path actions are all-or-nothing.
        expectRefused("a multi-path action is refused if any one path is refused") {
            try guardCaches.validate(
                DeleteAction.removePaths([
                    caches.appending(path: "good"),
                    home.appending(path: "Documents/important.pdf")
                ]),
                home: home
            )
        }
        expectAllowed("command actions carry no paths and always pass") {
            try PathGuard(roots: []).validate(
                DeleteAction.command(executable: "/usr/bin/true", args: [], displayName: "noop"),
                home: home
            )
        }
    }

    private mutating func checkSymlinks(scratch: URL, home: URL) async {
        let fm = FileManager.default
        let root = scratch.appending(path: "guard-root")
        let outside = scratch.appending(path: "guard-outside")
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            try fm.createDirectory(at: outside, withIntermediateDirectories: true)
            let secret = outside.appending(path: "secret.txt")
            try Data("private".utf8).write(to: secret)
            let inside = root.appending(path: "real.txt")
            try Data("cache".utf8).write(to: inside)

            let escaping = root.appending(path: "escape-link")
            let staying = root.appending(path: "local-link")
            try fm.createSymbolicLink(at: escaping, withDestinationURL: secret)
            try fm.createSymbolicLink(at: staying, withDestinationURL: inside)

            let guard0 = PathGuard(roots: [AllowedRoot(root)])
            expectRefused("a symlink pointing out of the root is refused, not followed") {
                try guard0.validate(escaping, home: home)
            }
            expectAllowed("a symlink pointing inside the root is allowed") {
                try guard0.validate(staying, home: home)
            }
            expect(fm.fileExists(atPath: secret.path), "the escaping link's target still exists")
        } catch {
            expect(false, "symlink fixture setup: \(error)")
        }
    }

    // MARK: - Sizing

    /// Hard links must be counted once, the way `du` does.
    ///
    /// Doc 02 claimed double counting was acceptable "same as `du`", which is not how `du`
    /// behaves. The cost of the mistake was a React Native `node_modules` reported at 26.3 GB
    /// against an actual 13.9 GB — 12 GB of space that deleting it would not have returned.
    private mutating func checkSizing(scratch: URL) async {
        let fm = FileManager.default
        let dir = scratch.appending(path: "sizing")
        let linked = dir.appending(path: "links")
        do {
            try fm.createDirectory(at: linked, withIntermediateDirectories: true)
        } catch {
            expect(false, "sizing fixture setup: \(error)")
            return
        }

        // One 8 MB file, then eight more paths pointing at the same inode — the shape React
        // Native's prebuilt .so files take inside node_modules.
        let original = dir.appending(path: "payload.bin")
        let payload = Data(repeating: 0x5A, count: 8 * 1_048_576)
        do {
            try payload.write(to: original)
            for index in 1...8 {
                try fm.linkItem(at: original, to: linked.appending(path: "copy-\(index).bin"))
            }
        } catch {
            expect(false, "hard-link fixture setup: \(error)")
            return
        }

        let sizer = DirectorySizer()
        guard let measured = try? await sizer.size(of: dir) else {
            expect(false, "sizing the fixture failed")
            return
        }

        // Nine paths, one inode: around 8 MB, not 72 MB.
        let mb = Double(measured.bytes) / 1_048_576
        expect(mb > 7 && mb < 12,
               String(format: "nine paths to one 8 MB inode measure %.1f MB, not 72 MB", mb))
        expect(measured.fileCount == 1,
               "the file count counts the inode once, not each of its nine paths")

        // A second, genuinely separate file must still be added.
        let second = dir.appending(path: "second.bin")
        try? payload.write(to: second)
        if let again = try? await sizer.size(of: dir) {
            let mb2 = Double(again.bytes) / 1_048_576
            expect(mb2 > mb + 6,
                   String(format: "a distinct file of the same size is still counted (%.1f MB)", mb2))
        }

        // And the result matches what `du -sk` reports for the same directory.
        let du = Process()
        du.executableURL = URL(fileURLWithPath: "/usr/bin/du")
        du.arguments = ["-sk", dir.path]
        let pipe = Pipe()
        du.standardOutput = pipe
        try? du.run()
        du.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        if let kb = Int64(output.split(separator: "\t").first?
            .trimmingCharacters(in: .whitespaces) ?? "") {
            let duBytes = kb * 1024
            let latest = (try? await sizer.size(of: dir))?.bytes ?? 0
            let drift = abs(Double(latest - duBytes)) / Double(max(duBytes, 1)) * 100
            expect(drift < 5,
                   String(format: "agrees with du within 5%% (du %lld KB, sizer %.0f KB)",
                          kb, Double(latest) / 1024))
        }

        try? fm.removeItem(at: dir)
        await checkRecursiveTree(scratch: scratch)
    }

    /// The recursive tree must total the same as `du` no matter how deep the content sits.
    ///
    /// An earlier version called `skipDescendants()` once past the depth limit, which skipped the
    /// *files* below too — `~/.gradle` reported 211 MB against an actual 595 MB. The depth limit
    /// is meant to bound how much detail is shown, never what the totals include.
    private mutating func checkRecursiveTree(scratch: URL) async {
        let fm = FileManager.default
        let root = scratch.appending(path: "deep")
        // Eight levels down — well past the tree's four-level display limit.
        let deep = root.appending(path: "a/b/c/d/e/f/g/h")
        do {
            try fm.createDirectory(at: deep, withIntermediateDirectories: true)
            try Data(repeating: 0x31, count: 4 * 1_048_576).write(to: deep.appending(path: "deep.bin"))
            try Data(repeating: 0x32, count: 2 * 1_048_576)
                .write(to: root.appending(path: "a/shallow.bin"))
            try Data(repeating: 0x33, count: 1_048_576).write(to: root.appending(path: "top.bin"))
        } catch {
            expect(false, "deep fixture setup: \(error)")
            return
        }
        defer { try? fm.removeItem(at: root) }

        guard let tree = await DirectorySizer().tree(of: root, maxDepth: 4) else {
            expect(false, "sizing the deep fixture failed")
            return
        }
        let totalMB = Double(tree.total.bytes) / 1_048_576
        expect(totalMB > 6.5 && totalMB < 8.5,
               String(format: "content eight levels down still counts: %.1f MB of 7 MB", totalMB))

        // Ancestors within the limit carry the deep content.
        let aMB = Double(tree.size(at: "a").bytes) / 1_048_576
        expect(aMB > 5.5,
               String(format: "an ancestor includes content below the display limit (%.1f MB)", aMB))
        expect(tree.size(at: "a/b/c/d").bytes >= 4 * 1_048_576,
               "the deepest shown level still includes everything beneath it")
        expect(tree.subdirectories(of: "a/b/c/d").isEmpty,
               "nothing is listed below the display limit")
        expect(tree.subdirectories(of: "").contains("a"), "immediate subfolders are listed")

        // And it agrees with du.
        let du = Process()
        du.executableURL = URL(fileURLWithPath: "/usr/bin/du")
        du.arguments = ["-sk", root.path]
        let pipe = Pipe()
        du.standardOutput = pipe
        try? du.run()
        du.waitUntilExit()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        if let kb = Int64(out.split(separator: "\t").first?.trimmingCharacters(in: .whitespaces) ?? "") {
            let drift = abs(Double(tree.total.bytes - kb * 1024)) / Double(max(kb * 1024, 1)) * 100
            expect(drift < 5,
                   String(format: "the recursive total agrees with du within 5%% (du %lld KB)", kb))
        }
    }

    // MARK: - Planning (nothing is deleted)

    /// Verifies the selection roll-up and the plan the confirmation sheet is built from.
    ///
    /// **This never invokes `DeletionEngine`.** Every node here is synthetic, with paths that do
    /// not exist, so the check cannot remove anything even if the logic under test is wrong.
    /// Actually carrying out a deletion is left to manual smoke testing.
    private mutating func checkPlanning(home: URL) {
        func fake(_ id: String, bytes: Int64, risk: Risk = .safe, children: [ScanNode] = [])
            -> ScanNode {
            // Under a folder that does not exist, so no real path is ever named.
            let url = home.appending(path: "Library/Caches/dev.vodicka.DevCleanerPro.notreal/\(id)")
            return ScanNode(
                id: "selfcheck/\(id)", title: id, url: url, size: bytes,
                risk: risk, action: .removePath(url), children: children
            )
        }

        let child = fake("child", bytes: 2_000_000)
        let parent = fake("parent", bytes: 5_000_000, children: [child])
        let sibling = fake("sibling", bytes: 3_000_000, risk: .careful)
        let blocked = ScanNode(
            id: "selfcheck/blocked", title: "blocked", size: 9_000_000,
            risk: .careful, action: .removePath(home.appending(path: "nope")),
            blockedReason: "Simulator is booted"
        )
        let info = ScanNode(
            id: "selfcheck/info", title: "info", size: 4_000_000, risk: .info, action: .none
        )
        let root = ScanNode(
            id: "selfcheck", title: "Self-check", size: 23_000_000, risk: .safe,
            children: [parent, sibling, blocked, info]
        )

        // Propagation and roll-up.
        var selection = SelectionModel()
        selection.set(parent, to: .on, in: [root])
        expect(selection.state(of: child.id) == .on, "checking a parent selects its children")
        expect(selection.state(of: root.id) == .partial,
               "a root with one of several children checked reads as partial")

        let targets = selection.deletionTargets(in: [root])
        expect(targets.count == 1 && targets[0].id == parent.id,
               "a parent and its child yield one target, the parent")

        let totals = selection.totals(in: [root])
        expect(totals.count == 1, "the footer counts one item, not two")
        expect(totals.bytes == parent.byteCount, "the parent's size is counted once")

        // A container carries no action of its own. Checking it must still select everything
        // underneath — this is what module and group rows do, and getting it wrong left every
        // one of them showing an ⓘ with no checkbox at all.
        expect(root.isSelectable, "a container with selectable descendants is itself selectable")
        expect(parent.isSelectable, "a group with a deletable child is selectable")
        expect(!info.isSelectable, "an info leaf is not selectable")
        expect(!blocked.isSelectable, "a blocked leaf is not selectable")

        let deadEnd = ScanNode(
            id: "selfcheck/deadend", title: "dead end", size: 1_000_000,
            risk: .info, action: .none,
            children: [
                ScanNode(id: "selfcheck/deadend/a", title: "a", size: 500_000,
                         risk: .info, action: .none),
                ScanNode(id: "selfcheck/deadend/b", title: "b", size: 500_000,
                         risk: .info, action: .none)
            ]
        )
        expect(!deadEnd.isSelectable,
               "a subtree made entirely of info rows is not selectable, so it keeps its ⓘ")

        var containerSelection = SelectionModel()
        containerSelection.toggle(root, in: [root])
        expect(containerSelection.state(of: parent.id) == .on,
               "checking the container selects a group two levels down")
        expect(containerSelection.state(of: child.id) == .on,
               "checking the container selects a leaf three levels down")
        expect(containerSelection.state(of: sibling.id) == .on,
               "checking the container selects every selectable sibling")
        expect(containerSelection.state(of: blocked.id) != .on,
               "checking the container leaves a blocked row alone")
        expect(containerSelection.state(of: info.id) != .on,
               "checking the container leaves an info row alone")

        let containerTargets = containerSelection.deletionTargets(in: [root])
        expect(containerTargets.count == 2,
               "a container with no action of its own yields its deletable children as targets")
        expect(containerTargets.contains { $0.id == parent.id }
               && containerTargets.contains { $0.id == sibling.id },
               "those targets are the topmost deletable nodes, not the leaves under them")

        // And clicking it again clears the lot.
        containerSelection.toggle(root, in: [root])
        expect(containerSelection.deletionTargets(in: [root]).isEmpty,
               "checking the container a second time clears everything under it")

        // Blocked and info nodes must never be swept up.
        var selectAll = SelectionModel()
        selectAll.selectAll(under: root, in: [root]) { _ in true }
        let allTargets = selectAll.deletionTargets(in: [root])
        expect(!allTargets.contains { $0.id == blocked.id },
               "select-all skips a blocked node")
        expect(!allTargets.contains { $0.id == info.id },
               "select-all skips an info node")
        expect(selectAll.state(of: root.id) == .on,
               "a root reads as fully selected once every selectable child is on, "
               + "even with blocked and info children present")

        var safeOnly = SelectionModel()
        safeOnly.selectAll(under: root, in: [root]) { $0.risk == .safe }
        let safeTargets = safeOnly.deletionTargets(in: [root])
        expect(safeTargets.contains { $0.id == parent.id }
               && !safeTargets.contains { $0.id == sibling.id },
               "select-all-safe takes the safe subtree and leaves the careful sibling")

        // Rows that can neither be ticked nor justify themselves are pruned. A folder the app
        // failed to classify reads "Safe" beside a checkbox that is not there, which looks
        // actionable and then refuses — worse than not listing it.
        let unclassified = ScanNode(
            id: "selfcheck/dead", title: "unclassified", size: 500_000_000,
            risk: .info, action: .none
        )
        let notable = ScanNode(
            id: "selfcheck/notable", title: "SIP-protected downloads", size: 60_000_000_000,
            risk: .info, action: .none, isAdvisory: true
        )
        let pruneRoot = ScanNode(
            id: "selfcheck/prune", title: "Module", size: 60_500_000_000, risk: .safe,
            children: [unclassified, notable, parent]
        )
        let pruned = pruneRoot.pruningDeadEnds()
        expect(pruned != nil, "a module with selectable content survives pruning")
        expect(pruned?.children.contains { $0.id == unclassified.id } == false,
               "an unclassified dead end is dropped")
        expect(pruned?.children.contains { $0.id == notable.id } == true,
               "an advisory row is kept — 59 GB of SIP-protected downloads is worth knowing about")
        expect(pruned?.children.contains { $0.id == parent.id } == true,
               "selectable content is kept")

        let allDead = ScanNode(
            id: "selfcheck/alldead", title: "Module", size: 100, risk: .safe,
            children: [ScanNode(id: "selfcheck/alldead/a", title: "a", size: 100,
                                risk: .info, action: .none)]
        )
        expect(allDead.pruningDeadEnds() == nil,
               "a group made entirely of dead ends disappears with them")

        let advisoryParent = ScanNode(
            id: "selfcheck/advparent", title: "Group", size: 100, risk: .info, action: .none,
            children: [notable]
        )
        expect(advisoryParent.pruningDeadEnds() != nil,
               "a group is kept when something advisory sits underneath it")

        // Risk must roll up: a parent claiming "Safe" while a child is "Careful" is an
        // assurance the tree cannot keep.
        expect(root.rolledUpRisk == .careful,
               "a root containing a careful child reports careful, not safe")
        expect(parent.rolledUpRisk == .safe, "a subtree that is all safe reports safe")
        expect(info.rolledUpRisk == .info, "an info leaf keeps reporting info")
        let mixedGroup = ScanNode(
            id: "selfcheck/mixed", title: "mixed", size: 10, risk: .safe,
            action: .removePath(home.appending(path: "nope-mixed")),
            children: [
                ScanNode(id: "selfcheck/mixed/a", title: "a", size: 5, risk: .safe,
                         action: .removePath(home.appending(path: "nope-a"))),
                ScanNode(id: "selfcheck/mixed/b", title: "b", size: 5, risk: .careful,
                         action: .removePath(home.appending(path: "nope-b")))
            ]
        )
        expect(mixedGroup.rolledUpRisk == .careful,
               "a group with one careful child among safe ones reports careful")
        expect(Risk.info.severity < Risk.safe.severity,
               "info never outranks a real warning coming from a child")

        // After the tree changes, container states must be re-derived — otherwise a group whose
        // children were just deleted sits on `partial` with nothing selected beneath it.
        var stale = SelectionModel()
        stale.set(child, to: .on, in: [root])
        expect(stale.state(of: parent.id) == .on,
               "the group reads on while its only child is selected")
        let afterDeletion = ScanNode(
            id: "selfcheck", title: "Self-check", size: 18_000_000, risk: .safe,
            children: [
                // `parent` survives, but the child under it has gone.
                ScanNode(id: "selfcheck/parent", title: "parent", size: 3_000_000,
                         risk: .safe, action: .removePath(home.appending(path: "nope-parent"))),
                sibling, blocked, info
            ]
        )
        stale.forget(child.id)
        expect(stale.state(of: parent.id) == .on,
               "forgetting a child alone leaves the stale group state behind")
        stale.resync(with: [afterDeletion])
        expect(stale.state(of: child.id) == .off,
               "resync drops the state of a node that no longer exists")
        expect(stale.state(of: parent.id) != .partial,
               "resync clears the partial state of a group whose children are gone")
        expect(stale.deletionTargets(in: [afterDeletion]).isEmpty
               || stale.deletionTargets(in: [afterDeletion]).allSatisfy { $0.id == "selfcheck/parent" },
               "resync leaves no phantom selection behind")

        // Two modules can legitimately offer the same path — a custom location pointed at a
        // code folder, and the Project build output module that scans the same folder. Counting
        // those bytes twice would inflate "will be freed" and then fail on the second delete.
        let shared = home.appending(path: "nope-shared/app/node_modules")
        let outerNode = ScanNode(
            id: "selfcheck/custom/app", title: "app",
            url: home.appending(path: "nope-shared/app"), size: 9_000_000,
            risk: .moderate, action: .removePath(home.appending(path: "nope-shared/app"))
        )
        let innerNode = ScanNode(
            id: "selfcheck/projects/node_modules", title: "node_modules",
            url: shared, size: 7_000_000,
            risk: .moderate, action: .removePath(shared)
        )
        let unrelated = ScanNode(
            id: "selfcheck/other", title: "elsewhere",
            url: home.appending(path: "nope-elsewhere"), size: 2_000_000,
            risk: .safe, action: .removePath(home.appending(path: "nope-elsewhere"))
        )
        let crossRootA = ScanNode(id: "selfcheck/rootA", title: "Custom", size: 9_000_000,
                                  risk: .safe, children: [outerNode])
        let crossRootB = ScanNode(id: "selfcheck/rootB", title: "Projects", size: 9_000_000,
                                  risk: .safe, children: [innerNode, unrelated])

        var crossSelection = SelectionModel()
        crossSelection.set(outerNode, to: .on, in: [crossRootA])
        crossSelection.set(innerNode, to: .on, in: [crossRootB])
        crossSelection.set(unrelated, to: .on, in: [crossRootB])

        let crossTargets = crossSelection.deletionTargets(in: [crossRootA, crossRootB])
        expect(!crossTargets.contains { $0.id == innerNode.id },
               "a path selected inside another selected path is dropped, even across modules")
        expect(crossTargets.contains { $0.id == outerNode.id },
               "the enclosing path is the one kept")
        expect(crossTargets.contains { $0.id == unrelated.id },
               "an unrelated path alongside it is untouched")
        let crossTotals = crossSelection.totals(in: [crossRootA, crossRootB])
        expect(crossTotals.bytes == 11_000_000,
               "the freed estimate counts the shared bytes once (9 MB + 2 MB, not 18 MB)")

        // The plan the sheet renders.
        let titles = ["selfcheck": "Self-check"]
        let trashPlan = DeletionPlan(
            mode: .trash, selection: selection, roots: [root], titles: titles
        )
        expect(trashPlan.totalCount == 1, "the plan lists one item")
        expect(trashPlan.totalBytes == parent.byteCount, "the plan totals the parent once")
        expect(trashPlan.groups.count == 1 && trashPlan.groups[0].title == "Self-check",
               "the plan groups by module using the sidebar title")
        expect(trashPlan.items.first?.operations.first?.hasPrefix("Move to Trash: ") == true,
               "trash mode describes itself as moving to the Trash")

        let permanentPlan = DeletionPlan(
            mode: .permanent, selection: selection, roots: [root], titles: titles
        )
        expect(permanentPlan.items.first?.operations.first?.hasPrefix("rm -rf ") == true,
               "permanent mode describes itself as rm -rf")

        var carefulSelection = SelectionModel()
        carefulSelection.set(sibling, to: .on, in: [root])
        let carefulPlan = DeletionPlan(
            mode: .trash, selection: carefulSelection, roots: [root], titles: titles
        )
        expect(carefulPlan.hasCareful,
               "a plan containing user data reports it, so warnOnCareful can gate the button")
        expect(!carefulPlan.hasCommands, "a path-only plan reports no commands")

        // Command items ignore the mode, which the sheet states once.
        let commandNode = ScanNode(
            id: "selfcheck/cmd", title: "runtime", size: 8_000_000, risk: .moderate,
            action: .command(executable: "/usr/bin/xcrun",
                             args: ["simctl", "delete", "unavailable"],
                             displayName: "Delete unavailable simulators")
        )
        let commandRoot = ScanNode(
            id: "selfcheck", title: "Self-check", size: 8_000_000, risk: .safe,
            children: [commandNode]
        )
        var commandSelection = SelectionModel()
        commandSelection.set(commandNode, to: .on, in: [commandRoot])
        let commandPlan = DeletionPlan(
            mode: .trash, selection: commandSelection, roots: [commandRoot], titles: titles
        )
        expect(commandPlan.hasCommands, "a command plan reports it has commands")
        expect(commandPlan.items.first?.operations.first
                == "/usr/bin/xcrun simctl delete unavailable",
               "a command item shows the exact command that will run")

        // Paths are abbreviated so the identifying part of a long path stays visible.
        expect(DeletionPlan.abbreviate(home.appending(path: "Library/Caches/x")) == "~/Library/Caches/x",
               "home-relative paths are shown with a tilde")
    }

    // MARK: - Git repositories

    /// Builds a repository with the two kinds of waste the module looks for and checks it finds
    /// them — and, more importantly, that it never offers `.git` itself for deletion.
    ///
    /// Uses a fake home directory so the real one is untouched; `ScanContext.home` is injectable
    /// precisely so a module can be exercised against a fixture.
    private mutating func checkGitModule(scratch: URL) async {
        let fm = FileManager.default
        let fakeHome = scratch.appending(path: "fakehome")
        let repository = fakeHome.appending(path: "myproject")
        let packDirectory = repository.appending(path: ".git/objects/pack")
        do {
            try fm.createDirectory(at: packDirectory, withIntermediateDirectories: true)
            // An interrupted pack: the exact shape that left 14.1 GB behind on the real machine.
            try Data(repeating: 0x70, count: 6 * 1_048_576)
                .write(to: packDirectory.appending(path: "tmp_pack_AbCdEf"))
            // A real pack alongside it, which must be left alone.
            try Data(repeating: 0x71, count: 2 * 1_048_576)
                .write(to: packDirectory.appending(path: "pack-abc123.pack"))
        } catch {
            expect(false, "git fixture setup: \(error)")
            return
        }
        defer { try? fm.removeItem(at: fakeHome) }

        expect(ProjectArtifactsModule.searchRoots(home: fakeHome).count == 1,
               "a folder containing a repository is discovered as a search root")
        let found = GitRepositoriesModule.findRepositories(
            under: ProjectArtifactsModule.searchRoots(home: fakeHome)
        )
        expect(found.contains { $0.lastPathComponent == "myproject" },
               "the repository inside it is found")

        let module = GitRepositoriesModule()
        let ctx = ScanContext(home: fakeHome, shell: Shell(), config: .defaults)
        guard let node = try? await module.scan(ctx) else {
            expect(false, "scanning the git fixture failed")
            return
        }

        var tmpPackRow: ScanNode?
        var gitDirectoryRows = 0
        node.forEachNode { child in
            if child.title == "Interrupted pack files" { tmpPackRow = child }
            if child.url?.lastPathComponent == ".git", child.isDeletable { gitDirectoryRows += 1 }
        }

        expect(tmpPackRow != nil, "the interrupted pack file is found")
        let mb = Double(tmpPackRow?.byteCount ?? 0) / 1_048_576
        expect(mb > 5 && mb < 8,
               String(format: "it reports the tmp_pack alone (%.1f MB), not the whole pack dir", mb))
        expect(tmpPackRow?.risk == .safe,
               "removing an interrupted pack is safe — nothing refers to it")

        // The single most important property of this module.
        expect(gitDirectoryRows == 0,
               "a .git directory is NEVER offered for deletion, at any risk level")

        let paths = tmpPackRow?.action.paths ?? []
        expect(paths.allSatisfy { $0.lastPathComponent.hasPrefix("tmp_pack") },
               "only tmp_pack files are ever targeted by path")
        expect(!paths.contains { $0.lastPathComponent.hasPrefix("pack-") },
               "a real pack file beside it is left alone")
    }

    // MARK: - Module registry

    /// The allowlist handed to `PathGuard` must be unambiguous.
    private mutating func checkRegistry(home: URL) {
        let roots = ModuleRegistry.allowedRoots(config: .defaults)
        let paths = roots.map(\.url.path)
        expect(paths.count == Set(paths).count,
               "the allowlist contains no duplicate paths, so PathGuard cannot pick "
               + "non-deterministically between two entries for one directory")
        expect(!roots.isEmpty, "the allowlist is not empty")

        // Every module declares at least one root, or is command-driven and declares none.
        for module in ModuleRegistry.allModules(config: .defaults) {
            let id = module.descriptor.id
            expect(module.roots.allSatisfy { $0.url.path.hasPrefix("/") },
                   "\(id): every declared root is an absolute path")
        }

        // Nothing a module declared may itself be deny-listed — that would mean a module asking
        // for something it can never have.
        let guardAll = PathGuard(roots: roots)
        for root in roots where root.deletableItself {
            expect(guardAll.allows(root.url, home: home),
                   "a root marked deletableItself is actually deletable: "
                   + DeletionPlan.abbreviate(root.url))
        }
    }

    // MARK: - Configuration

    /// Custom-root validation and malformed-JSON handling — doc 04's manual matrix rows 10 and 11.
    ///
    /// Writes only into the self-check's own scratch directory.
    private mutating func checkConfig(scratch: URL, home: URL) {
        let fm = FileManager.default

        // Row 11: a custom root pointing somewhere untouchable is refused at the point of entry.
        for (path, why) in [
            ("~", "the home folder itself"),
            ("~/Documents", "a documents folder"),
            ("~/Library", "the Library folder itself"),
            ("/", "the filesystem root"),
            ("/System/Library", "a system folder"),
            ("relative/path", "a relative path")
        ] {
            expect(ConfigStore.validateCustomRoot(path: path) != nil,
                   "custom root refused: \(path) — \(why)")
        }
        expect(ConfigStore.validateCustomRoot(path: "~/Library/Caches/DoesNotExist-\(UUID())") != nil,
               "custom root refused: a folder that does not exist")

        // A folder that genuinely is fine must be accepted, or the gate is useless.
        let acceptable = scratch.appending(path: "acceptable-root")
        try? fm.createDirectory(at: acceptable, withIntermediateDirectories: true)
        expect(ConfigStore.validateCustomRoot(path: acceptable.path) == nil,
               "custom root accepted: an ordinary folder under ~/Library/Caches")

        // Row 10: malformed JSON is reported and the file is left exactly as written.
        let configDir = scratch.appending(path: "config")
        let store = ConfigStore(directory: configDir)
        let broken = #"{ "minItemSizeMB": 50, "customRoots": [ }"#
        try? fm.createDirectory(at: configDir, withIntermediateDirectories: true)
        try? Data(broken.utf8).write(to: store.fileURL)

        let loaded = store.load()
        expect(loaded.error != nil, "malformed config.json is reported rather than swallowed")
        expect(loaded.config == UserConfig.defaults,
               "malformed config.json falls back to defaults")
        let afterwards = (try? String(contentsOf: store.fileURL, encoding: .utf8)) ?? ""
        expect(afterwards == broken,
               "malformed config.json is left untouched, so hand-written roots survive a typo")

        // A partial file picks up defaults for what it omits rather than failing.
        let partial = #"{ "minItemSizeMB": 200 }"#
        try? Data(partial.utf8).write(to: store.fileURL)
        let partialLoad = store.load()
        expect(partialLoad.error == nil, "a partial config.json loads without complaint")
        expect(partialLoad.config.minItemSizeMB == 200, "the value it does specify is honoured")
        expect(partialLoad.config.autoScanOnLaunch == UserConfig.defaults.autoScanOnLaunch,
               "omitted values fall back to defaults")

        // A round trip must survive, including the design's `rebuild` spelling for `moderate`.
        let aliased = #"{ "customRoots": [ { "id": "x", "title": "X", "path": "~/x", "risk": "rebuild", "groupBy": "flat" } ] }"#
        try? Data(aliased.utf8).write(to: store.fileURL)
        let aliasLoad = store.load()
        expect(aliasLoad.config.customRoots.first?.risk == .moderate,
               "the design's \"rebuild\" spelling decodes as moderate")

        var round = UserConfig.defaults
        round.minItemSizeMB = 123
        round.customRoots = [
            CustomRoot(id: "bazel", title: "Bazel", path: "~/.cache/bazel",
                       risk: .careful, groupBy: .flat),
            CustomRoot(id: "work", title: "Work", path: "~/work",
                       risk: .moderate, groupBy: .children)
        ]
        try? store.save(round)
        let reloaded = store.load().config
        expect(reloaded == round, "config survives a save and reload unchanged")

        // A folder added in the sidebar has to still be there after a relaunch, which means every
        // field of it must round-trip — not just the path.
        expect(reloaded.customRoots.count == 2, "both custom folders survive a relaunch")
        expect(reloaded.customRoots.first?.risk == .careful, "the risk setting survives")
        expect(reloaded.customRoots.first?.groupBy == .flat, "the grouping setting survives")
        expect(reloaded.customRoots.last?.title == "Work", "the title survives")
        expect(reloaded.customRoots.last?.path == "~/work",
               "the path is stored tilde-abbreviated, so it survives a change of user name")

        // The launch warning shows until it is dismissed with "don't show again", and that
        // choice has to survive a relaunch or the setting is meaningless.
        expect(UserConfig.defaults.disclaimerAcknowledged == false,
               "the launch warning is shown on a fresh install")
        var acknowledged = UserConfig.defaults
        acknowledged.disclaimerAcknowledged = true
        try? store.save(acknowledged)
        expect(store.load().config.disclaimerAcknowledged,
               "dismissing the launch warning survives a relaunch")
        let olderFile = #"{ "minItemSizeMB": 10 }"#
        try? Data(olderFile.utf8).write(to: store.fileURL)
        expect(store.load().config.disclaimerAcknowledged == false,
               "a config written before the warning existed still shows it once")
    }

    /// A one-group plan over hand-made nodes.
    private func plan(mode: DeleteMode, nodes: [ScanNode]) -> DeletionPlan {
        let root = ScanNode(
            id: "selfcheck", title: "Self-check", size: nodes.reduce(0) { $0 + $1.byteCount },
            risk: .safe, children: nodes
        )
        var selection = SelectionModel()
        for node in nodes { selection.set(node, to: .on, in: [root]) }
        return DeletionPlan(
            mode: mode, selection: selection, roots: [root], titles: ["selfcheck": "Self-check"]
        )
    }
}
