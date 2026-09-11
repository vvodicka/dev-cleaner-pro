import SwiftUI
import DevCleanerProCore

/// The sidebar. Navigation, not a filter: clicking a module expands it in the tree and scrolls
/// there, leaving every other module visible (`docs/00-decisions.md` #7).
struct ModuleJumpList: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(spacing: 0) {
            List {
                Section("Jump to module") {
                    ForEach(state.modules) { descriptor in
                        ModuleRow(descriptor: descriptor)
                    }
                }

                // Always present, even before anything has been added — otherwise the only way
                // to discover that you can scan your own folders is to go looking in Settings.
                Section("Your folders") {
                    ForEach(state.config.customRoots) { root in
                        CustomRootRow(root: root)
                    }
                    AddFolderButton(style: .compact)
                }
            }
            .listStyle(.sidebar)

            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Text(state.scanSummary)
                if !state.emptyModules.isEmpty {
                    // A module that ran and found nothing is invisible, which is
                    // indistinguishable from one that is broken or was never written. Saying so
                    // costs one line and answers the question before it is asked.
                    Menu {
                        ForEach(state.emptyModules) { descriptor in
                            Label(
                                "\(descriptor.title) — \(descriptor.requiresTool ?? "nothing found")",
                                systemImage: descriptor.systemImage
                            )
                        }
                    } label: {
                        Text("\(state.emptyModules.count) module"
                             + (state.emptyModules.count == 1 ? "" : "s")
                             + " found nothing")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }
}

/// One sidebar row: icon, name, and size right-aligned in monospaced digits so the column does
/// not jitter as modules finish at different times. 28 pt per the design.
struct ModuleRow: View {
    @Environment(AppState.self) private var state
    let descriptor: ModuleDescriptor

    private var isScanning: Bool { state.scanning.contains(descriptor.id) }
    private var errorMessage: String? { state.errors[descriptor.id] }
    private var size: Int64? { state.results[descriptor.id]?.size }

    var body: some View {
        Button {
            state.jump(to: descriptor.id)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: descriptor.systemImage)
                    .frame(width: 16)
                Text(descriptor.title)
                    .lineLimit(1)
                Spacer(minLength: 4)

                if isScanning {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                } else if let errorMessage {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .help(errorMessage)
                }

                Text(isScanning || errorMessage != nil ? "—" : ByteFormatting.string(size))
                    .font(.system(size: 11.5).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .frame(height: 28)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}


/// One user-added folder in the sidebar. Clicking it jumps to that folder inside the Custom
/// locations tree, the same way a module row does.
struct CustomRootRow: View {
    @Environment(AppState.self) private var state
    let root: CustomRoot

    @State private var isHovering = false
    @State private var confirmingRemoval = false

    /// Sizes come from the last scan, so a folder added since then reads "—" until it finishes.
    private var size: Int64? {
        state.results["custom"]?.node(withID: "custom/\(root.id)")?.size
    }

    var body: some View {
        HStack(spacing: 8) {
            Button {
                state.jump(to: "custom")
                state.expanded.insert("custom/\(root.id)")
                state.scrollTarget = "custom/\(root.id)"
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "folder")
                        .frame(width: 16)
                        .foregroundStyle(.secondary)
                    Text(root.title)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if !isHovering {
                        Text(ByteFormatting.string(size))
                            .font(.system(size: 11.5).monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(root.path)

            // Revealed on hover rather than hidden in a context menu: removing a folder you
            // added is not an advanced operation, and a menu you have to know about is the same
            // as no button at all.
            if isHovering {
                Button {
                    confirmingRemoval = true
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Stop scanning this folder")
                .accessibilityLabel("Remove \(root.title) from the scan list")
            }
        }
        .frame(height: 28)
        .onHover { isHovering = $0 }
        .confirmationDialog(
            "Stop scanning \(root.title)?",
            isPresented: $confirmingRemoval
        ) {
            Button("Remove from the list", role: .destructive) {
                state.removeCustomLocation(id: root.id)
            }
        } message: {
            Text("The folder itself is left alone — this only takes it out of the scan.")
        }
        .contextMenu {
            Button("Reveal in Finder") {
                state.reveal(ScanNode(id: root.id, title: root.title, url: root.url))
            }
            Button("Copy path") { state.copyToClipboard(root.url.path) }
            Divider()
            Picker("Risk", selection: Binding(
                get: { root.risk },
                set: { risk in
                    state.updateCustomLocation(id: root.id) { $0.risk = risk }
                }
            )) {
                ForEach(Risk.allCases, id: \.self) { Text($0.displayLabel).tag($0) }
            }
            Picker("Detail", selection: Binding(
                get: { root.groupBy },
                set: { grouping in
                    state.updateCustomLocation(id: root.id) { $0.groupBy = grouping }
                }
            )) {
                Text("Show subfolders").tag(CustomRoot.GroupBy.children)
                Text("One row only").tag(CustomRoot.GroupBy.flat)
            }
            Divider()
            Button("Remove from the list", role: .destructive) {
                state.removeCustomLocation(id: root.id)
            }
        }
    }
}
