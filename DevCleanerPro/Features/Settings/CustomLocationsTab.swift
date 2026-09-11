import SwiftUI
import UniformTypeIdentifiers
import DevCleanerProCore

/// Frame 1f — the folders the user adds on top of the built-in modules.
struct CustomLocationsTab: View {
    @Environment(AppState.self) private var state

    @State private var selection: CustomRoot.ID?
    @State private var showingImporter = false
    @State private var rejection: String?

    private var roots: [CustomRoot] { state.config.customRoots }

    /// Measured sizes come from the last scan, so a row added since then shows "—" until rescan.
    private func size(of root: CustomRoot) -> Int64? {
        state.results["custom"]?.node(withID: "custom/\(root.id)")?.size
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Folders DevCleanerPro should scan in addition to the built-in modules.")
                .font(.callout)
                .foregroundStyle(.secondary)

            table

            HStack {
                Toggle("Ask again before deleting anything marked Careful", isOn: Binding(
                    get: { state.config.warnOnCareful },
                    set: { value in state.updateConfig { $0.warnOnCareful = value } }
                ))
                .controlSize(.small)
                Spacer()
                Button("Open config file") { state.openConfigFile() }
                    .controlSize(.small)
            }
        }
        .padding(16)
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: true
        ) { result in
            guard case .success(let urls) = result else { return }
            for url in urls { add(url) }
        }
        .alert("Cannot add that folder", isPresented: Binding(
            get: { rejection != nil },
            set: { if !$0 { rejection = nil } }
        )) {
            Button("OK") { rejection = nil }
        } message: {
            Text(rejection ?? "")
        }
    }

    private var table: some View {
        VStack(spacing: 0) {
            Table(roots, selection: $selection) {
                TableColumn("Title") { root in
                    Text(root.title)
                }
                .width(min: 120, ideal: 170)

                TableColumn("Path") { root in
                    Text(root.path)
                        .font(.system(size: 11.5).monospaced())
                        .foregroundStyle(.secondary)
                        .help(root.path)
                }

                TableColumn("Risk") { root in
                    RiskBadge(risk: root.risk)
                }
                .width(90)

                TableColumn("Size") { root in
                    Text(ByteFormatting.string(size(of: root)))
                        .font(.system(size: 12).monospacedDigit())
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(80)
            }
            .tableStyle(.bordered)

            Divider()
            HStack(spacing: 2) {
                Button {
                    showingImporter = true
                } label: {
                    Image(systemName: "plus")
                }
                .help("Add a folder")

                Button {
                    remove()
                } label: {
                    Image(systemName: "minus")
                }
                .disabled(selection == nil)
                .help("Remove the selected folder")

                Spacer()

                if let selection, let root = roots.first(where: { $0.id == selection }) {
                    Picker("Risk", selection: Binding(
                        get: { root.risk },
                        set: { setRisk($0, for: root) }
                    )) {
                        ForEach(Risk.allCases, id: \.self) { risk in
                            Text(risk.displayLabel).tag(risk)
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(width: 110)

                    Picker("Grouping", selection: Binding(
                        get: { root.groupBy },
                        set: { setGrouping($0, for: root) }
                    )) {
                        Text("One row per subfolder").tag(CustomRoot.GroupBy.children)
                        Text("One row for the folder").tag(CustomRoot.GroupBy.flat)
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(width: 180)
                }
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color(nsColor: .controlBackgroundColor))
        }
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color(nsColor: .separatorColor))
        )
    }

    // MARK: - Mutation

    /// Delegates to `AppState`, so the sidebar button, the empty state and this tab all add a
    /// folder the same way and persist it the same way.
    private func add(_ url: URL) {
        if case .refused(let reason) = state.addCustomLocation(url) {
            rejection = reason
        }
    }

    private func remove() {
        guard let selection else { return }
        state.removeCustomLocation(id: selection)
        self.selection = nil
    }

    private func setRisk(_ risk: Risk, for root: CustomRoot) {
        state.updateCustomLocation(id: root.id) { $0.risk = risk }
    }

    private func setGrouping(_ grouping: CustomRoot.GroupBy, for root: CustomRoot) {
        state.updateCustomLocation(id: root.id) { $0.groupBy = grouping }
    }
}
