import SwiftUI
import DevCleanerProCore

/// The persistent 44 pt footer: selection on the left, the delete button on the right, and the
/// all-time freed figure far right. Phase 2 wires the selection totals and the sheet.
struct FooterBarView: View {
    @Environment(AppState.self) private var state

    private var totals: (bytes: Int64, count: Int) { state.selectionTotals }
    private var selectedBytes: Int64 { totals.bytes }
    private var selectedCount: Int { totals.count }

    private var hasSelection: Bool { selectedCount > 0 }

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 4) {
                Text("Selected:")
                Text(ByteFormatting.string(selectedBytes))
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                Text("· \(selectedCount) items")
            }
            .font(.system(size: 13))

            Button("Clear") { state.clearSelection() }
                .buttonStyle(.link)
                .disabled(!hasSelection)

            Spacer()

            Button("Delete…") { state.requestDelete() }
                .buttonStyle(.borderedProminent)
                // The destructive tint appears only here, on the permanent segment, and in the
                // confirmation sheet — never on the rows themselves.
                .tint(state.deleteMode == .permanent ? .red : .accentColor)
                .disabled(!hasSelection || state.isDeleting)
                .keyboardShortcut(.delete, modifiers: .command)

            Text("Freed all-time: \(state.stats.formattedTotal)")
                .font(.system(size: 11.5))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(.bar)
    }
}
