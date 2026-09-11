import SwiftUI
import DevCleanerProCore

/// The Settings scene. Four tabs, matching the design's frame 1f.
///
/// Every value here except the delete mode lives in `config.json`, which is the source of truth
/// (`docs/00-decisions.md`) — so editing the file by hand and editing it here are the same thing.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
            ModulesSettingsTab()
                .tabItem { Label("Modules", systemImage: "square.stack.3d.up") }
            CustomLocationsTab()
                .tabItem { Label("Custom locations", systemImage: "folder.badge.gearshape") }
            AdvancedSettingsTab()
                .tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
        }
        .frame(width: 620, height: 460)
    }
}

// MARK: - General

struct GeneralSettingsTab: View {
    @Environment(AppState.self) private var state

    var body: some View {
        Form {
            Section {
                Picker("Default delete mode", selection: Binding(
                    get: { state.deleteMode },
                    set: { state.deleteMode = $0 }
                )) {
                    ForEach(DeleteMode.allCases, id: \.self) { mode in
                        Text(mode.segmentLabel).tag(mode)
                    }
                }
                Text("Tool commands — simulator and Docker operations — are always permanent, "
                     + "whichever mode is set.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Scan on launch", isOn: Binding(
                    get: { state.config.autoScanOnLaunch },
                    set: { value in state.updateConfig { $0.autoScanOnLaunch = value } }
                ))

                Picker("Hide items smaller than", selection: Binding(
                    get: { state.config.minItemSizeMB },
                    set: { value in state.updateConfig { $0.minItemSizeMB = value } }
                )) {
                    ForEach(MinimumSize.allCases, id: \.self) { option in
                        Text(option.label).tag(option.megabytes)
                    }
                }
                Text("Hidden items still count toward the size of the group they are in, so the "
                     + "totals stay accurate.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                // The design put this on the Custom locations tab; it is global, so it belongs
                // here (`docs/00-decisions.md` #12).
                Toggle("Ask again before deleting anything marked Careful", isOn: Binding(
                    get: { state.config.warnOnCareful },
                    set: { value in state.updateConfig { $0.warnOnCareful = value } }
                ))
                Text("Careful means user data or device state — simulator contents, archives, "
                     + "database volumes, uncommitted local history.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Modules

struct ModulesSettingsTab: View {
    @Environment(AppState.self) private var state

    /// Every module the app knows about, not only the ones currently visible — otherwise a
    /// module the user disabled would vanish from the list that is meant to re-enable it.
    private var allModules: [ModuleDescriptor] {
        ModuleRegistry.allModules(config: state.config).map(\.descriptor)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Modules that are turned off are skipped entirely. A module whose tool is not "
                 + "installed hides itself regardless.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(16)

            List {
                ForEach(allModules) { descriptor in
                    Toggle(isOn: Binding(
                        get: { state.config.isEnabled(descriptor.id) },
                        set: { enabled in
                            state.updateConfig { config in
                                config.disabledModules.removeAll { $0 == descriptor.id }
                                if !enabled { config.disabledModules.append(descriptor.id) }
                            }
                        }
                    )) {
                        HStack(spacing: 8) {
                            Image(systemName: descriptor.systemImage)
                                .frame(width: 18)
                                .foregroundStyle(.secondary)
                            Text(descriptor.title)
                            if let tool = descriptor.requiresTool {
                                Text("needs \(tool)")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }
            .listStyle(.inset)

            Divider()
            HStack {
                Spacer()
                Button("Rescan now") { state.rescanAll() }
                    .disabled(state.isScanning)
            }
            .padding(12)
        }
    }
}

// MARK: - Advanced

struct AdvancedSettingsTab: View {
    @Environment(AppState.self) private var state
    @State private var confirmingReset = false

    var body: some View {
        Form {
            Section("Statistics") {
                LabeledContent("Freed all time", value: state.stats.formattedTotal)
                LabeledContent("Cleaning sessions", value: "\(state.stats.sessions)")
                Button("Reset statistics…") { confirmingReset = true }
            }

            Section("Configuration") {
                LabeledContent("Config file") {
                    Text(DeletionPlan.abbreviate(state.configFileURL))
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
                Button("Open config file") { state.openConfigFile() }
                Text("Everything on the General and Custom locations tabs is stored here. "
                     + "Editing the file by hand is supported; if the JSON is invalid the app "
                     + "says so and leaves your file untouched.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Permissions") {
                LabeledContent("Full Disk Access",
                               value: state.fullDiskAccessGranted ? "Granted" : "Not granted")
                Button("Open System Settings") { state.openFullDiskAccessSettings() }
                Text("Needed only for iOS device backups and a few system caches. Everything "
                     + "else is measured without it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            "Reset the freed-space statistics?",
            isPresented: $confirmingReset
        ) {
            Button("Reset", role: .destructive) { state.resetStats() }
        } message: {
            Text("This only clears the counter. Nothing on disk changes.")
        }
    }
}
