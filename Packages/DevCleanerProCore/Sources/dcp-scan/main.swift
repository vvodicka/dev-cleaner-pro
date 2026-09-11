import Foundation
import DevCleanerProCore

// Diagnostic CLI over the same engine the app uses.
//
//   swift run dcp-scan                       every available module, one line per module
//   swift run dcp-scan --tree xcode          full tree for one module
//   swift run dcp-scan --tree xcode --depth 2
//   swift run dcp-scan --plan                what the current selection model would delete
//   swift run dcp-scan --roots               the PathGuard allowlist
//
// Exists so module totals can be compared against `du -sh` and parser output inspected without
// the GUI in the way.

struct Options {
    var treeModuleID: String?
    var depth = 99
    var showRoots = false
    var selfCheck = false
    var minMB: Int?
    var configDir: String?
    var auditIDs = false
}

func parseOptions() -> Options {
    var o = Options()
    var args = Array(CommandLine.arguments.dropFirst()).makeIterator()
    while let arg = args.next() {
        switch arg {
        case "--tree": o.treeModuleID = args.next()
        case "--depth": o.depth = Int(args.next() ?? "") ?? 99
        case "--min-mb": o.minMB = Int(args.next() ?? "")
        case "--config-dir": o.configDir = args.next()
        case "--roots": o.showRoots = true
        case "--self-check": o.selfCheck = true
        case "--audit-ids": o.auditIDs = true
        case "-h", "--help":
            print("""
            dcp-scan — diagnostic scanner

              --tree <moduleID>   print the full tree for one module
              --depth <n>         limit tree depth (default: all)
              --min-mb <n>        override the size filter (default: from config.json)
              --config-dir <dir>  read config.json from here instead of Application Support,
                                  so a scan can be tried without touching the real settings
              --roots             print the PathGuard allowlist and exit
              --self-check        verify PathGuard and the plan logic (deletes nothing)
              --audit-ids         scan every module and report duplicate node IDs or a parent
                                  whose risk badge understates a child's
            """)
            exit(0)
        default:
            FileHandle.standardError.write(Data("unknown argument: \(arg)\n".utf8))
            exit(2)
        }
    }
    return o
}

func pad(_ s: String, _ width: Int) -> String {
    s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
}

func padLeft(_ s: String, _ width: Int) -> String {
    s.count >= width ? s : String(repeating: " ", count: width - s.count) + s
}

func printTree(_ node: ScanNode, depth: Int, limit: Int) {
    guard depth <= limit else { return }
    let indent = String(repeating: "  ", count: depth)
    // What the UI would draw in the marker column, so the tree can be checked for rows that
    // wrongly show an ⓘ instead of a checkbox.
    let marker = node.isBlocked ? "[x]" : (node.isSelectable ? "[ ]" : " i ")
    let label = indent + marker + " " + node.title
    // The rolled-up risk, which is what the UI shows — a parent must not read "Safe" while a
    // child is "Careful".
    var flags: [String] = [node.rolledUpRisk.displayLabel]
    if node.rolledUpRisk != node.risk { flags.append("own=\(node.risk.displayLabel)") }
    if node.isBlocked { flags.append("BLOCKED") }
    if case .command(let exe, let args, _) = node.action {
        // A relative executable cannot be launched by Process, and the mistake would otherwise
        // only surface at delete time — so it is called out here rather than shown as a basename.
        let shown = exe.hasPrefix("/")
            ? URL(fileURLWithPath: exe).lastPathComponent
            : "!!NOT-ABSOLUTE:\(exe)"
        flags.append("cmd: \(shown) \(args.joined(separator: " "))")
    }
    print("\(pad(label, 62))\(padLeft(ByteFormatting.string(node.size), 10))  \(flags.joined(separator: " · "))")
    if let subtitle = node.subtitle, !subtitle.isEmpty {
        print("\(pad(indent + "  ↳ " + subtitle, 62))")
    }
    for child in node.children { printTree(child, depth: depth + 1, limit: limit) }
}

let options = parseOptions()

if options.selfCheck {
    exit(await SelfCheck.run())
}

let store = options.configDir.map { ConfigStore(directory: URL(fileURLWithPath: $0)) }
    ?? ConfigStore()
let loaded = store.load()
if let error = loaded.error {
    FileHandle.standardError.write(Data("config: \(error.localizedDescription)\n".utf8))
}
var config = loaded.config
if let minMB = options.minMB { config.minItemSizeMB = minMB }

if options.showRoots {
    print("PathGuard allowlist:")
    for root in ModuleRegistry.allowedRoots(config: config).sorted(by: { $0.url.path < $1.url.path }) {
        print("  \(root.deletableItself ? "[self+contents]" : "[contents only]") \(root.url.path)")
    }
    exit(0)
}

let shell = Shell()
let ctx = ScanContext(shell: shell, config: config) { line in
    FileHandle.standardError.write(Data("  … \(line)\n".utf8))
}

let available = await ModuleRegistry.activeModules(ctx: ctx)
let selected = options.treeModuleID.map { id in available.filter { $0.descriptor.id == id } }
    ?? available

if selected.isEmpty {
    let names = available.map { $0.descriptor.id }.joined(separator: ", ")
    FileHandle.standardError.write(Data("no such module. available: \(names)\n".utf8))
    exit(1)
}

if options.auditIDs {
    var problems = 0
    for module in available {
        guard let node = try? await module.scan(ctx) else {
            print("  \(module.descriptor.id): scan failed")
            continue
        }
        // Duplicate IDs make SwiftUI render a row twice, tie both copies' selection together
        // and multiply them on every rescan — exactly what a shared Docker image ID caused.
        var counts: [String: Int] = [:]
        var understated: [String] = []
        node.forEachNode { child in
            counts[child.id, default: 0] += 1
            if child.risk.severity < child.rolledUpRisk.severity {
                understated.append("\(child.title): shows \(child.risk.displayLabel), "
                                   + "contains \(child.rolledUpRisk.displayLabel)")
            }
        }
        let dupes = counts.filter { $0.value > 1 }
        let missingSubtitle = { () -> Int in
            var n = 0
            node.forEachNode { if ($0.subtitle ?? "").isEmpty { n += 1 } }
            return n
        }()
        let total = counts.count
        problems += dupes.count
        print("  \(pad(module.descriptor.id, 14)) nodes=\(pad(String(total), 6))"
              + "duplicate-ids=\(pad(String(dupes.count), 4))"
              + "risk-understated=\(pad(String(understated.count), 4))"
              + "no-subtitle=\(missingSubtitle)")
        for (id, n) in dupes.sorted(by: { $0.key < $1.key }).prefix(5) {
            print("      !! \(id) appears \(n)x")
        }
        var bare: [String] = []
        node.forEachNode { if ($0.subtitle ?? "").isEmpty { bare.append($0.title) } }
        for title in bare.prefix(20) { print("      no-subtitle: \(title)") }
    }
    print("")
    print(problems == 0 ? "no duplicate node IDs" : "\(problems) duplicate node IDs")
    exit(problems == 0 ? 0 : 1)
}

let clock = ContinuousClock()
let start = clock.now
var total: Int64 = 0
let flattener = TreeFlattener()

for await result in ScanCoordinator().scanAll(modules: selected, ctx: ctx) {
    switch result.result {
    case .success(let raw):
        let node = flattener.prepared(
            raw, sortedBy: .sizeDescending, minimumBytes: config.minItemSizeBytes
        ) ?? raw
        total += node.byteCount
        let seconds = Double(result.duration.components.seconds)
            + Double(result.duration.components.attoseconds) / 1e18
        if options.treeModuleID == nil {
            print("\(pad(node.title, 26))\(padLeft(ByteFormatting.string(node.size), 10))"
                  + "  \(String(format: "%.1f", seconds))s")
        } else {
            print("── \(node.title) — \(String(format: "%.1f", seconds))s "
                  + "— filter \(config.minItemSizeMB) MB ──")
            printTree(node, depth: 0, limit: options.depth)
        }
    case .failure(let failure):
        print("\(pad(result.moduleID, 26))\(padLeft("—", 10))  \(failure.message)")
    }
}

let elapsed = start.duration(to: clock.now)
print("")
print("total \(ByteFormatting.string(total)) in "
      + "\(String(format: "%.1f", Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18))s")
