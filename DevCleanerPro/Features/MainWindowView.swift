import SwiftUI
import DevCleanerProCore

/// The single window: sidebar navigation, one unified tree, persistent footer.
///
/// Metrics from the component spec — sidebar 240 (min 200), footer 44, window min 900×600.
struct MainWindowView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        NavigationSplitView {
            ModuleJumpList()
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        } detail: {
            VStack(spacing: 0) {
                if let configError = state.configError {
                    ConfigErrorBanner(message: configError)
                }

                if state.hasResults || state.isScanning {
                    ScanTreeView()
                } else {
                    EmptyStateView()
                }

                Divider()
                FooterBarView()
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .overlay(alignment: .bottom) {
                if let toast = state.toast {
                    ToastOverlay(toast: toast)
                }
            }
            .animation(.easeOut(duration: 0.22), value: state.toast?.id)
        }
        .toolbar { toolbarContent }
        .task { state.onAppear() }
        .sheet(isPresented: Binding(
            get: { state.showingDisclaimer },
            set: { if !$0 { state.showingDisclaimer = false } }
        )) {
            DisclaimerSheet()
                // There is one way out of this sheet, and it is reading it.
                .interactiveDismissDisabled(true)
        }
        .sheet(item: Binding(
            get: { state.pendingPlan.map(IdentifiedPlan.init) },
            set: { if $0 == nil { state.cancelDelete() } }
        )) { wrapped in
            DeleteConfirmSheet(plan: wrapped.plan)
        }
        .sheet(item: Binding(
            get: { state.deleteProgress },
            set: { if $0 == nil { state.dismissProgress() } }
        )) { progress in
            DeleteProgressSheet(progress: progress)
                // Closing mid-run would leave the deletion invisible, so the sheet stays until
                // the run finishes and Done becomes enabled.
                .interactiveDismissDisabled(!progress.isFinished)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem {
            Button("Rescan", systemImage: "arrow.clockwise") { state.rescanAll() }
                .help("Rescan all modules (⌘R)")
                .disabled(state.isScanning)
        }
        ToolbarItem {
            Picker("Delete mode", selection: Binding(
                get: { state.deleteMode },
                set: { state.deleteMode = $0 }
            )) {
                ForEach(DeleteMode.allCases, id: \.self) { mode in
                    Text(mode.segmentLabel).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .help("Where deleted items go. Tool commands are always permanent.")
        }
        ToolbarItem {
            // Kept from FR-3.4 even though the design dropped it from the toolbar
            // (`docs/00-decisions.md` #8).
            Menu {
                Picker("Minimum size", selection: Binding(
                    get: { state.config.minItemSizeMB },
                    set: { mb in state.updateConfig { $0.minItemSizeMB = mb } }
                )) {
                    ForEach(MinimumSize.allCases, id: \.self) { option in
                        Text(option.label).tag(option.megabytes)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                Label("Minimum size", systemImage: "line.3.horizontal.decrease.circle")
            }
            .help("Hide items smaller than this. They still count toward their parent's size.")
        }
        ToolbarItem {
            Button("Collapse all", systemImage: "chevron.up.chevron.down") {
                state.collapseAll()
            }
            .help("Collapse every module")
        }
    }
}

/// The design's filter steps.
enum MinimumSize: CaseIterable {
    case none, mb50, mb200, gb1

    var megabytes: Int {
        switch self {
        case .none: 0
        case .mb50: 50
        case .mb200: 200
        case .gb1: 1024
        }
    }

    var label: String {
        switch self {
        case .none: "Show everything"
        case .mb50: "50 MB and larger"
        case .mb200: "200 MB and larger"
        case .gb1: "1 GB and larger"
        }
    }
}

/// `config.json` could not be read. The file is deliberately left as-is so hand-written custom
/// locations survive a syntax slip.
struct ConfigErrorBanner: View {
    @Environment(AppState.self) private var state
    let message: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.system(size: 12))
                .lineLimit(2)
            Spacer(minLength: 8)
            Button("Open config file") { state.openConfigFile() }
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color.orange.opacity(0.12))
        .overlay(alignment: .bottom) { Divider() }
    }
}


/// `DeletionPlan` is a value with no identity of its own; the sheet needs one.
struct IdentifiedPlan: Identifiable {
    let plan: DeletionPlan
    let id = UUID()

    init(_ plan: DeletionPlan) { self.plan = plan }
}
