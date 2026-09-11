import SwiftUI
import DevCleanerProCore

@main
struct DevCleanerProApp: App {
    @State private var state = AppState()
    @NSApplicationDelegateAdaptor(TerminationGuard.self) private var terminationGuard

    var body: some Scene {
        WindowGroup {
            MainWindowView()
                .environment(state)
                // The design's stated minimum, and the smallest width that fits the toolbar
                // without collapsing controls into an overflow menu.
                .frame(minWidth: 900, minHeight: 600)
                .onAppear { terminationGuard.state = state }
        }
        .defaultSize(width: 1180, height: 740)   // frame 1a
        .commands {
            CommandGroup(after: .newItem) {
                Button("Rescan") { state.rescanAll() }
                    .keyboardShortcut("r", modifiers: .command)
                Button("Cancel Scan") { state.cancelScan() }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(!state.isScanning)
                Divider()
                Button("Collapse All") { state.collapseAll() }
                    .keyboardShortcut("[", modifiers: [.command, .shift])
                Divider()
                Button("Delete Selected…") { state.requestDelete() }
                    .keyboardShortcut(.delete, modifiers: .command)
                    .disabled(state.selectionTotals.count == 0 || state.isDeleting)
                Button("Clear Selection") { state.clearSelection() }
                    .keyboardShortcut(.escape, modifiers: [])
                    .disabled(state.selectionTotals.count == 0)
            }
        }

        Settings {
            SettingsView()
                .environment(state)
        }
    }
}
